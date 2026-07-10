//go:build linux || darwin

package session

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/repo"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
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
			Primary: &agent.RoleConfig{Agent: "claude", Window: -1},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	svc.Registry = registry
	svc.CLIResolver = func(_ string) (string, error) { return "echo questmaster", nil }
	return svc, runner
}

func launchCmds(primary string) map[agent.Role]string {
	return map[agent.Role]string{
		agent.RolePrimary: primary,
	}
}

func findLaunchArgContaining(runner *mockRunner, needle string) string {
	for _, call := range runner.calls {
		for _, arg := range call.args {
			if strings.Contains(arg, needle) {
				return arg
			}
		}
	}
	return ""
}

func createTestManifest(t *testing.T, store *state.Store, id, title, cwd, sessionType string) {
	t.Helper()
	m := state.Manifest{
		SessionID:   id,
		Title:       title,
		Cwd:         cwd,
		SessionType: sessionType,
		AgentPath:   "/usr/bin",
		Agents: []state.AgentManifest{
			{Name: "claude", Role: "primary", CLI: "/usr/bin/claude", Window: 1},
		},
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("create manifest %s: %v", id, err)
	}
}

func makeGitDir(t *testing.T, root string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0o755); err != nil {
		t.Fatalf("mkdir .git: %v", err)
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

func writePiResumeState(t *testing.T, store *state.Store, sessionID, resumeID string) {
	t.Helper()
	setTestStateRoot(t, store.Root())
	lastEvent := time.UnixMilli(1).UTC()
	sessionsDir := filepath.Join(t.TempDir(), ".pi", "agent", "sessions", "project")
	if err := state.SaveSessionState(sessionID, &state.SessionState{
		SessionID: sessionID,
		Version:   state.SchemaVersion,
		SeenAt:    lastEvent,
		Panes: map[string]state.PaneState{
			"primary": {
				Role:        "primary",
				Agent:       "pi",
				State:       "idle",
				LastEvent:   lastEvent,
				SessionFile: filepath.Join(sessionsDir, "2026-05-03T15-16-13-988Z_"+resumeID+".jsonl"),
			},
		},
	}); err != nil {
		t.Fatalf("save Pi state: %v", err)
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

	if result.SessionID != "qm-1234567890" {
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
	if got := runner.envVars[result.SessionID+":"+state.SessionEnv]; got != result.SessionID {
		t.Fatalf("%s env = %q, want %q", state.SessionEnv, got, result.SessionID)
	}

	// Verify cleanup hook was set
	if !runner.hasCall("set-hook") {
		t.Fatal("cleanup hook not set")
	}
}

func TestStart_PersistsDisplayColor(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	svc.Now = func() int64 { return 1234567892 }

	result, err := svc.Start(t.Context(), StartOpts{
		Title:        "color-test",
		Cwd:          t.TempDir(),
		DisplayColor: "magenta",
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if m.Display == nil {
		t.Fatal("manifest display metadata = nil, want persisted color")
	}
	if m.Display.Color != "magenta" {
		t.Fatalf("display.color = %q, want magenta", m.Display.Color)
	}
	if state.ParseColorStamp(m.Display.ColorChangedAt).IsZero() {
		t.Fatalf("display.color_changed_at = %q, want a real timestamp", m.Display.ColorChangedAt)
	}
}

func TestStart_ExplicitDisplayColorSeedsRepoColor(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	svc.Now = func() int64 { return 1234567894 }

	cwd := t.TempDir()
	makeGitDir(t, cwd)
	result, err := svc.Start(t.Context(), StartOpts{
		Title:        "repo-color-test",
		Cwd:          cwd,
		DisplayColor: "orange",
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if result.SessionID == "" {
		t.Fatal("session ID is empty")
	}

	r, ok := repo.Resolve(cwd)
	if !ok {
		t.Fatalf("resolve %q: not a repo", cwd)
	}
	rc, ok, err := state.NewRepoColorStore(svc.Store.Root()).Get(r.Identity)
	if err != nil {
		t.Fatalf("get repo color: %v", err)
	}
	if !ok {
		t.Fatal("repo color missing")
	}
	if rc.Color != "orange" {
		t.Fatalf("repo color = %q, want orange", rc.Color)
	}
	if state.ParseColorStamp(rc.UpdatedAt).IsZero() {
		t.Fatalf("repo updated_at = %q, want a real timestamp", rc.UpdatedAt)
	}
}

func TestStart_ExplicitDisplayColorReplacesExistingRepoColor(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	svc.Now = func() int64 { return 1234567895 }

	cwd := t.TempDir()
	makeGitDir(t, cwd)
	r, ok := repo.Resolve(cwd)
	if !ok {
		t.Fatalf("resolve %q: not a repo", cwd)
	}
	repoColors := state.NewRepoColorStore(svc.Store.Root())
	if err := repoColors.Set(r.Identity, "green"); err != nil {
		t.Fatalf("seed repo color: %v", err)
	}

	if _, err := svc.Start(t.Context(), StartOpts{
		Title:        "repo-color-replace-test",
		Cwd:          cwd,
		DisplayColor: "magenta",
	}); err != nil {
		t.Fatalf("start: %v", err)
	}

	rc, ok, err := repoColors.Get(r.Identity)
	if err != nil {
		t.Fatalf("get repo color: %v", err)
	}
	if !ok {
		t.Fatal("repo color missing")
	}
	if rc.Color != "magenta" {
		t.Fatalf("repo color = %q, want magenta", rc.Color)
	}
}

func TestStart_DoesNotPersistDefaultDisplayColor(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	svc.Now = func() int64 { return 1234567893 }

	result, err := svc.Start(t.Context(), StartOpts{
		Title: "no-color-test",
		Cwd:   t.TempDir(),
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if m.Display != nil {
		t.Fatalf("manifest display metadata = %#v, want nil when no display color was selected", m.Display)
	}
}

func TestStart_StandaloneUsesStandalonePrompt(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 1234567891 }

	task := "inspect the standalone session"
	if _, err := svc.Start(t.Context(), StartOpts{
		Title:  "solo",
		Cwd:    t.TempDir(),
		Prompt: task,
	}); err != nil {
		t.Fatalf("start standalone: %v", err)
	}

	launch := findLaunchArgContaining(runner, task)
	if launch == "" {
		t.Fatal("expected standalone launch command containing task prompt")
	}
	if !strings.Contains(launch, agent.NewClaude(agent.AgentConfig{}).StandalonePrompt()) {
		t.Fatalf("expected standalone launch command to include standalone system prompt, got %q", launch)
	}
	if strings.Contains(launch, agent.NewClaude(agent.AgentConfig{}).WorkerPrompt()) {
		t.Fatalf("standalone launch command must not include worker prompt, got %q", launch)
	}
	if strings.Count(launch, task) != 1 {
		t.Fatalf("expected standalone task prompt once in launch command, got %q", launch)
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

	assertPrimaryOnlyLayout(t, runner, result.SessionID)
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

func TestStart_DoesNotLaunchTrackerPane(t *testing.T) {
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

	assertPrimaryOnlyLayout(t, runner, result.SessionID)
}

func TestStart_FromAppFlagUsesPrimaryOnlyLayout(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 4343 }

	result, err := svc.Start(t.Context(), StartOpts{
		Title:   "app-session",
		Cwd:     t.TempDir(),
		FromApp: true,
	})
	if err != nil {
		t.Fatalf("start from app: %v", err)
	}

	assertPrimaryOnlyLayout(t, runner, result.SessionID)
	primaryLaunched := false
	for _, call := range runner.calls {
		if len(call.args) > 0 && call.args[0] == "respawn-pane" && flagVal(call.args, "-t") == result.SessionID+":0.0" {
			primaryLaunched = true
			break
		}
	}
	if !primaryLaunched {
		t.Fatalf("expected primary agent to launch in pane 0.0, calls=%v", runner.calls)
	}
}

func TestStart_TitledSessionDoesNotSetTmuxWindowName(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 4545 }

	result, err := svc.Start(t.Context(), StartOpts{
		Title:   "Add GLM 5.2",
		Cwd:     t.TempDir(),
		FromApp: true,
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if m.Title != "Add GLM 5.2" {
		t.Fatalf("title = %q, want original", m.Title)
	}
	if m.WindowName != "" {
		t.Fatalf("window_name = %q, want blank", m.WindowName)
	}
	if got := runner.windowNames[result.SessionID+":0"]; got != "" {
		t.Fatalf("rename-window name = %q, want no custom name", got)
	}

	for _, call := range runner.calls {
		if len(call.args) > 0 && call.args[0] == "new-session" {
			if got := flagVal(call.args, "-n"); got != "" {
				t.Fatalf("new-session -n = %q, want omitted", got)
			}
			return
		}
	}
	t.Fatalf("new-session call not found: %+v", runner.calls)
}

func TestSpawn_FromAppFlagUsesPrimaryOnlyLayout(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 4444 }
	createTestManifest(t, svc.Store, "qm-master", "master", t.TempDir(), "master")

	result, err := svc.Spawn(t.Context(), "qm-master", SpawnOpts{
		Title:    "app-worker",
		FromApp:  true,
		Registry: svc.Registry,
	})
	if err != nil {
		t.Fatalf("spawn from app: %v", err)
	}

	assertPrimaryOnlyLayout(t, runner, result.SessionID)
}

func assertPrimaryOnlyLayout(t *testing.T, runner *mockRunner, sessionID string) {
	t.Helper()
	if runner.paneRoles[sessionID+":0.0"] != "primary" {
		t.Fatalf("expected primary in pane 0.0, got %q", runner.paneRoles[sessionID+":0.0"])
	}
	if got := runner.paneRoles[sessionID+":0.1"]; got != "" {
		t.Fatalf("unexpected role in pane 0.1: %q", got)
	}
	if got := runner.paneTitles[sessionID+":0.0"]; got == "Tracker" {
		t.Fatalf("layout should not title pane 0.0 as Tracker")
	}
	if runner.hasCall("split-window") {
		t.Fatalf("launch should not split a companion pane, calls=%v", runner.calls)
	}
	if runner.hasCall("resize-pane") {
		t.Fatalf("launch should not resize panes, calls=%v", runner.calls)
	}
	if runner.hasCall("set-hook", "-t", sessionID, "client-attached") {
		t.Fatalf("launch should not install client-attached resize hook, calls=%v", runner.calls)
	}
	if runner.hasCall("set-hook", "-t", sessionID, "client-resized") {
		t.Fatalf("launch should not install client-resized resize hook, calls=%v", runner.calls)
	}
}

// ---------------------------------------------------------------------------
// Continue tests
// ---------------------------------------------------------------------------

func TestContinue_AlreadyRunning(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["qm-existing"] = true

	result, err := svc.Continue(t.Context(), "qm-existing")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}
	if !result.Reattach {
		t.Fatal("expected reattach=true for running session")
	}
	if result.SessionID != "qm-existing" {
		t.Fatalf("expected qm-existing, got %s", result.SessionID)
	}
}

func TestContinue_AlreadyRunningWithPiSidecarMissingManifest(t *testing.T) {
	svc, runner := setupService(t)
	sessionID := "qm-running-pi-missing-manifest"
	resumeID := "019dee69-5623-75c9-9317-04bf7f94e92b"
	runner.sessions[sessionID] = true
	writePiResumeState(t, svc.Store, sessionID, resumeID)

	result, err := svc.Continue(t.Context(), sessionID)
	if err != nil {
		t.Fatalf("continue should reattach even when Pi resume persistence cannot read manifest: %v", err)
	}
	if !result.Reattach {
		t.Fatal("expected reattach=true for running session")
	}
	if result.SessionID != sessionID {
		t.Fatalf("SessionID = %q, want %q", result.SessionID, sessionID)
	}
}

func TestContinue_StoppedRegular(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-stopped", "old-work", cwd, "")

	result, err := svc.Continue(t.Context(), "qm-stopped")
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
	if !runner.sessions["qm-stopped"] {
		t.Fatal("session not recreated in tmux")
	}
}

func TestLaunchSessionPropagatesAppOwnedEnvironment(t *testing.T) {
	setTestStateRoot(t, t.TempDir())
	questHome := t.TempDir()
	bin := filepath.Join(t.TempDir(), "qm")
	prefix := filepath.Join(t.TempDir(), "qm-shim")
	focusSocket := filepath.Join(t.TempDir(), "app-focus.sock")
	t.Setenv("QUESTMASTER_HOME", questHome)
	t.Setenv("QUESTMASTER_BIN", bin)
	t.Setenv("QUESTMASTER_PATH_PREFIX", prefix)
	t.Setenv("QUESTMASTER_APP", "1")
	t.Setenv("QUESTMASTER_FOCUS_SOCKET", focusSocket)

	svc, runner := setupService(t)
	result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()})
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	wants := map[string]string{
		"QUESTMASTER_HOME":         questHome,
		"QUESTMASTER_BIN":          bin,
		"QUESTMASTER_PATH_PREFIX":  prefix,
		"QUESTMASTER_APP":          "1",
		"QUESTMASTER_FOCUS_SOCKET": focusSocket,
	}
	for key, want := range wants {
		if got := runner.envVars[result.SessionID+":"+key]; got != want {
			t.Fatalf("tmux env %s = %q, want %q", key, got, want)
		}
	}
}

func TestContinue_StoppedRegularUsesStandalonePrompt(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-standalone", "old-work", cwd, "")

	if _, err := svc.Continue(t.Context(), "qm-standalone"); err != nil {
		t.Fatalf("continue: %v", err)
	}

	launch := findLaunchArgContaining(runner, agent.NewClaude(agent.AgentConfig{}).StandalonePrompt())
	if launch == "" {
		t.Fatal("expected continue launch command containing standalone prompt")
	}
	if strings.Contains(launch, agent.NewClaude(agent.AgentConfig{}).WorkerPrompt()) {
		t.Fatalf("continued standalone session must not use worker prompt, got %q", launch)
	}
}

func TestContinue_StoppedMaster(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master", "orchestrator", cwd, "master")

	result, err := svc.Continue(t.Context(), "qm-master")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}
	if result.Reattach {
		t.Fatal("expected reattach=false")
	}
	if !result.Master {
		t.Fatal("expected master=true for master session")
	}

	if !runner.sessions["qm-master"] {
		t.Fatal("master session not recreated")
	}
	assertPrimaryOnlyLayout(t, runner, "qm-master")
}

func TestContinue_MissingManifest(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	_, err := svc.Continue(t.Context(), "qm-ghost")
	if err == nil {
		t.Fatal("expected error for missing manifest")
	}
}

func TestContinue_MasterCascadesOrphanedWorkers(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	cwd := t.TempDir()

	// Create master with two workers in its list
	createTestManifest(t, svc.Store, "qm-mst", "master", cwd, "master")
	if err := svc.Store.AddWorker("qm-mst", "qm-w1"); err != nil {
		t.Fatalf("add worker: %v", err)
	}
	if err := svc.Store.AddWorker("qm-mst", "qm-w2"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	// Create worker manifests (orphaned — have manifest, no tmux session)
	createTestManifest(t, svc.Store, "qm-w1", "worker-one", cwd, "")
	if err := svc.Store.Update("qm-w1", func(m *state.Manifest) {
		m.SetExtra("parent_session", "qm-mst")
	}); err != nil {
		t.Fatalf("set parent: %v", err)
	}
	createTestManifest(t, svc.Store, "qm-w2", "worker-two", cwd, "")
	if err := svc.Store.Update("qm-w2", func(m *state.Manifest) {
		m.SetExtra("parent_session", "qm-mst")
	}); err != nil {
		t.Fatalf("set parent: %v", err)
	}

	result, err := svc.Continue(t.Context(), "qm-mst")
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
	if !runner.sessions["qm-w1"] {
		t.Error("qm-w1 tmux session not created")
	}
	if !runner.sessions["qm-w2"] {
		t.Error("qm-w2 tmux session not created")
	}
}

func TestContinue_MasterSkipsAliveWorkers(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	cwd := t.TempDir()

	createTestManifest(t, svc.Store, "qm-m2", "master", cwd, "master")
	if err := svc.Store.AddWorker("qm-m2", "qm-alive"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	createTestManifest(t, svc.Store, "qm-alive", "alive-worker", cwd, "")
	if err := svc.Store.Update("qm-alive", func(m *state.Manifest) {
		m.SetExtra("parent_session", "qm-m2")
	}); err != nil {
		t.Fatalf("set parent: %v", err)
	}

	// Mark worker as already running
	runner.sessions["qm-alive"] = true

	result, err := svc.Continue(t.Context(), "qm-m2")
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

	createTestManifest(t, svc.Store, "qm-m3", "master", cwd, "master")
	// Add a worker ID but do NOT create a manifest for it (ghost)
	if err := svc.Store.AddWorker("qm-m3", "qm-ghost"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	result, err := svc.Continue(t.Context(), "qm-m3")
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

	createTestManifest(t, svc.Store, "qm-rm", "master", cwd, "master")
	if err := svc.Store.AddWorker("qm-rm", "qm-rw1"); err != nil {
		t.Fatalf("add worker: %v", err)
	}
	createTestManifest(t, svc.Store, "qm-rw1", "orphan", cwd, "")
	if err := svc.Store.Update("qm-rw1", func(m *state.Manifest) {
		m.SetExtra("parent_session", "qm-rm")
	}); err != nil {
		t.Fatalf("set parent: %v", err)
	}

	// Master is already alive — reattach path
	runner.sessions["qm-rm"] = true

	result, err := svc.Continue(t.Context(), "qm-rm")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}
	if !result.Reattach {
		t.Fatal("expected reattach=true for running master")
	}
	if !result.Master {
		t.Fatal("expected master=true")
	}
	if len(result.RevivedWorkers) != 1 || result.RevivedWorkers[0] != "qm-rw1" {
		t.Fatalf("expected [qm-rw1] revived, got %v", result.RevivedWorkers)
	}
	if !runner.sessions["qm-rw1"] {
		t.Error("orphaned worker tmux session not created")
	}
}

func TestContinue_MasterReportsCorruptManifestAsFailure(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	cwd := t.TempDir()

	createTestManifest(t, svc.Store, "qm-m4", "master", cwd, "master")
	if err := svc.Store.AddWorker("qm-m4", "qm-corrupt"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	// Write corrupt JSON as the worker manifest
	corruptPath := filepath.Join(svc.Store.Root(), "qm-corrupt.json")
	if err := os.WriteFile(corruptPath, []byte("{bad json"), 0o644); err != nil {
		t.Fatalf("write corrupt manifest: %v", err)
	}

	result, err := svc.Continue(t.Context(), "qm-m4")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}

	if len(result.RevivedWorkers) != 0 {
		t.Fatalf("expected 0 revived, got %v", result.RevivedWorkers)
	}
	if len(result.FailedWorkers) != 1 || result.FailedWorkers[0] != "qm-corrupt" {
		t.Fatalf("expected [qm-corrupt] in failed, got %v", result.FailedWorkers)
	}
}

// ---------------------------------------------------------------------------
// Delete tests
// ---------------------------------------------------------------------------

func TestDelete_RunningSession(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["qm-del"] = true
	createTestManifest(t, svc.Store, "qm-del", "deleteme", t.TempDir(), "")

	if err := svc.Delete(t.Context(), "qm-del"); err != nil {
		t.Fatalf("delete: %v", err)
	}
	if runner.sessions["qm-del"] {
		t.Fatal("session still exists after delete")
	}
	if _, err := svc.Store.Read("qm-del"); err == nil {
		t.Fatal("manifest still exists after delete")
	}
}

func TestDelete_MasterCascadesWorkers(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	masterID := "qm-delmaster"
	runningWorkerID := "qm-delmaster-w1"
	stoppedWorkerID := "qm-delmaster-w2"
	ghostWorkerID := "qm-delmaster-ghost"

	createTestManifest(t, svc.Store, masterID, "master", t.TempDir(), "master")
	for _, workerID := range []string{runningWorkerID, stoppedWorkerID} {
		createTestManifest(t, svc.Store, workerID, "worker", t.TempDir(), "")
		if err := svc.Store.Update(workerID, func(m *state.Manifest) {
			m.SetExtra("parent_session", masterID)
		}); err != nil {
			t.Fatalf("set parent %s: %v", workerID, err)
		}
	}
	for _, workerID := range []string{runningWorkerID, stoppedWorkerID, ghostWorkerID} {
		if err := svc.Store.AddWorker(masterID, workerID); err != nil {
			t.Fatalf("add worker %s: %v", workerID, err)
		}
	}

	runner.sessions[masterID] = true
	runner.sessions[runningWorkerID] = true

	if err := svc.Delete(t.Context(), masterID); err != nil {
		t.Fatalf("delete master: %v", err)
	}

	for _, sessionID := range []string{masterID, runningWorkerID, stoppedWorkerID} {
		if runner.sessions[sessionID] {
			t.Fatalf("tmux session %s still exists after delete", sessionID)
		}
		if _, err := svc.Store.Read(sessionID); err == nil {
			t.Fatalf("manifest %s still exists after delete", sessionID)
		}
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

func TestPromote_UpdatesManifestAndNotifiesPrimary(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["qm-worker"] = true
	createTestManifest(t, svc.Store, "qm-worker", "worker", t.TempDir(), "")
	if err := svc.Store.Update("qm-worker", func(m *state.Manifest) {
		m.SetExtra("codex_thread_id", "codex-kept-123")
	}); err != nil {
		t.Fatalf("set codex_thread_id: %v", err)
	}

	runner.paneRoles["qm-worker:0.0"] = "tracker"
	runner.paneRoles["qm-worker:0.1"] = "primary"
	runner.paneRoles["qm-worker:0.2"] = "shell"

	if err := svc.Promote(t.Context(), "qm-worker"); err != nil {
		t.Fatalf("promote: %v", err)
	}

	m, err := svc.Store.Read("qm-worker")
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if m.SessionType != "master" {
		t.Fatalf("expected master, got %q", m.SessionType)
	}
	if m.WindowName != "" {
		t.Fatalf("expected manifest WindowName cleared, got %q", m.WindowName)
	}
	if len(m.Agents) != 1 || m.Agents[0].Role != "primary" || m.Agents[0].Name != "claude" {
		t.Fatalf("expected primary agent kept after promote, got %+v", m.Agents)
	}
	if got := m.ExtraString("codex_thread_id"); got != "codex-kept-123" {
		t.Fatalf("expected codex_thread_id preserved, got %q", got)
	}

	if got := runner.windowNames["qm-worker:0"]; got != "" {
		t.Errorf("expected no window rename, got %q", got)
	}

	if !runner.hasSendText("qm-worker:0.1", promotedMasterRoleMessage) {
		t.Fatalf("expected master role update sent to primary pane")
	}
	if provider, err := svc.Registry.Get("claude"); err == nil && runner.hasSendText("qm-worker:0.1", provider.MasterPrompt()) {
		t.Fatalf("promote should not send the full master prompt")
	}
}

func TestPromote_AlreadyMaster(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["qm-master"] = true
	createTestManifest(t, svc.Store, "qm-master", "orch", t.TempDir(), "master")

	// Should be a no-op
	if err := svc.Promote(t.Context(), "qm-master"); err != nil {
		t.Fatalf("promote idempotent: %v", err)
	}
}

func TestPromote_NotRunning(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	createTestManifest(t, svc.Store, "qm-dead", "dead", t.TempDir(), "")

	err := svc.Promote(t.Context(), "qm-dead")
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
	createTestManifest(t, svc.Store, "qm-master", "orch", cwd, "master")

	result, err := svc.Spawn(t.Context(), "qm-master", SpawnOpts{
		Title: "worker-1",
	})
	if err != nil {
		t.Fatalf("spawn: %v", err)
	}

	// Verify worker registered
	workers, err := svc.Store.GetWorkers("qm-master")
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

func TestSpawn_InheritsMasterDisplayColor(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	counter := int64(5050)
	svc.Now = func() int64 { counter++; return counter }

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master", "orch", cwd, "master")
	if err := svc.Store.Update("qm-master", func(m *state.Manifest) {
		m.Display = &state.DisplayMetadata{Color: "cyan"}
	}); err != nil {
		t.Fatalf("set master display color: %v", err)
	}

	result, err := svc.Spawn(t.Context(), "qm-master", SpawnOpts{Title: "worker-color"})
	if err != nil {
		t.Fatalf("spawn: %v", err)
	}

	wm, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read worker manifest: %v", err)
	}
	if wm.Display == nil {
		t.Fatal("worker display metadata = nil, want inherited color")
	}
	if wm.Display.Color != "cyan" {
		t.Fatalf("worker display.color = %q, want cyan", wm.Display.Color)
	}
}

func TestSpawn_ExplicitDisplayColorOverridesMasterDisplayColor(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	counter := int64(5100)
	svc.Now = func() int64 { counter++; return counter }

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master", "orch", cwd, "master")
	if err := svc.Store.Update("qm-master", func(m *state.Manifest) {
		m.Display = &state.DisplayMetadata{Color: "cyan"}
	}); err != nil {
		t.Fatalf("set master display color: %v", err)
	}

	result, err := svc.Spawn(t.Context(), "qm-master", SpawnOpts{
		Title:        "worker-explicit-color",
		DisplayColor: "pink",
	})
	if err != nil {
		t.Fatalf("spawn: %v", err)
	}

	wm, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read worker manifest: %v", err)
	}
	if wm.Display == nil {
		t.Fatal("worker display metadata = nil, want explicit color")
	}
	if wm.Display.Color != "pink" {
		t.Fatalf("worker display.color = %q, want pink", wm.Display.Color)
	}
	if state.ParseColorStamp(wm.Display.ColorChangedAt).IsZero() {
		t.Fatalf("worker display.color_changed_at = %q, want a real timestamp", wm.Display.ColorChangedAt)
	}
}

func TestSpawn_DoesNotInheritMissingMasterDisplayColor(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	counter := int64(5150)
	svc.Now = func() int64 { counter++; return counter }

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master", "orch", cwd, "master")

	result, err := svc.Spawn(t.Context(), "qm-master", SpawnOpts{Title: "worker-no-color"})
	if err != nil {
		t.Fatalf("spawn: %v", err)
	}

	wm, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read worker manifest: %v", err)
	}
	if wm.Display != nil {
		t.Fatalf("worker display metadata = %#v, want nil when master has no display color", wm.Display)
	}
}

// TestSpawn_SeedsStartingStateForCodex verifies that spawning a codex
// worker pre-populates state.json with State="starting" and
// Activity="started" for the primary pane, so the tracker never renders
// "unknown" in the gap between spawn and the SessionStart hook.
func TestSpawn_SeedsStartingStateForCodex(t *testing.T) {
	svc, _ := setupService(t)
	setTestStateRoot(t, t.TempDir())
	counter := int64(5500)
	svc.Now = func() int64 { counter++; return counter }

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master", "orch", cwd, "master")
	if err := svc.Store.Update("qm-master", func(m *state.Manifest) {
		m.Agents = []state.AgentManifest{{
			Name:   "codex",
			Role:   "primary",
			CLI:    "/bin/sh",
			Window: 0,
		}}
		m.Extra = nil
	}); err != nil {
		t.Fatalf("update master manifest: %v", err)
	}

	result, err := svc.Spawn(t.Context(), "qm-master", SpawnOpts{Title: "codex-worker"})
	if err != nil {
		t.Fatalf("spawn: %v", err)
	}

	ss, err := state.LoadSessionState(result.SessionID)
	if err != nil {
		t.Fatalf("load session state: %v", err)
	}
	if ss == nil {
		t.Fatal("expected seeded state.json, got nil")
	}
	pane, ok := ss.Panes["primary"]
	if !ok {
		t.Fatalf("expected primary pane in seeded state, got %+v", ss.Panes)
	}
	if pane.State != "starting" {
		t.Errorf("primary State = %q, want \"starting\"", pane.State)
	}
	if pane.Activity != "started" {
		t.Errorf("primary Activity = %q, want \"started\"", pane.Activity)
	}
	if pane.Agent != "codex" {
		t.Errorf("primary Agent = %q, want \"codex\"", pane.Agent)
	}
}

func TestSpawn_FromMasterPassesPromptAsFirstTurn(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	counter := int64(5100)
	svc.Now = func() int64 { counter++; return counter }

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master", "orch", cwd, "master")

	task := "inspect the worker startup flow"
	result, err := svc.Spawn(t.Context(), "qm-master", SpawnOpts{
		Title:  "worker-1",
		Prompt: task,
	})
	if err != nil {
		t.Fatalf("spawn: %v", err)
	}

	wm, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read worker manifest: %v", err)
	}
	if got := wm.ExtraString("initial_prompt"); got != task {
		t.Fatalf("initial_prompt: got %q, want %q", got, task)
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
		t.Fatal("expected worker launch command containing prompt")
	}
	if !strings.Contains(launch, agent.NewClaude(agent.AgentConfig{}).WorkerPrompt()) {
		t.Fatalf("expected worker launch command to include worker system prompt, got %q", launch)
	}
	if !strings.Contains(launch, "-- '"+task+"'") {
		t.Fatalf("expected worker prompt as first user turn, got %q", launch)
	}
	if strings.Count(launch, task) != 1 {
		t.Fatalf("expected worker prompt exactly once in launch command, got %q", launch)
	}
}

// Spawn threads the default worker model (and any --model override) all the way
// through SpawnOpts → StartOpts → CmdOpts → the launched claude command.
func TestSpawn_WorkerModelDefaultAndOverride(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	counter := int64(5200)
	svc.Now = func() int64 { counter++; return counter }

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master", "orch", cwd, "master")

	defaultTask := "run the default model worker"
	if _, err := svc.Spawn(t.Context(), "qm-master", SpawnOpts{Title: "w1", Prompt: defaultTask}); err != nil {
		t.Fatalf("spawn default: %v", err)
	}
	overrideTask := "run the escalated worker"
	if _, err := svc.Spawn(t.Context(), "qm-master", SpawnOpts{Title: "w2", Prompt: overrideTask, Model: "opus"}); err != nil {
		t.Fatalf("spawn override: %v", err)
	}

	if def := launchContaining(runner.calls, defaultTask); !strings.Contains(def, "--model 'sonnet'") {
		t.Fatalf("default worker should pin the role default model, got %q", def)
	}
	if over := launchContaining(runner.calls, overrideTask); !strings.Contains(over, "--model 'opus'") {
		t.Fatalf("--model override should thread through spawn, got %q", over)
	}
}

// Spawn threads the default worker reasoning effort (and any override) all the
// way through SpawnOpts → StartOpts → CmdOpts → the launched Claude command.
func TestSpawn_WorkerReasoningEffortDefaultAndOverride(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	counter := int64(5300)
	svc.Now = func() int64 { counter++; return counter }

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master", "orch", cwd, "master")

	defaultTask := "use the default reasoning effort"
	if _, err := svc.Spawn(t.Context(), "qm-master", SpawnOpts{Title: "w1", Prompt: defaultTask}); err != nil {
		t.Fatalf("spawn default: %v", err)
	}
	overrideTask := "use lower reasoning effort"
	if _, err := svc.Spawn(t.Context(), "qm-master", SpawnOpts{Title: "w2", Prompt: overrideTask, ReasoningEffort: "high"}); err != nil {
		t.Fatalf("spawn override: %v", err)
	}

	if def := launchContaining(runner.calls, defaultTask); !strings.Contains(def, "--effort xhigh") {
		t.Fatalf("default worker should keep xhigh reasoning, got %q", def)
	}
	if over := launchContaining(runner.calls, overrideTask); !strings.Contains(over, "--effort 'high'") {
		t.Fatalf("--reasoning-effort override should thread through spawn, got %q", over)
	}
}

func launchContaining(calls []callRecord, needle string) string {
	for _, call := range calls {
		for _, arg := range call.args {
			if strings.Contains(arg, needle) {
				return arg
			}
		}
	}
	return ""
}

// Spawn with no flags must inherit the master's primary agent.
func TestSpawn_FromMasterInheritsPrimaryAgent(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	counter := int64(6000)
	svc.Now = func() int64 { counter++; return counter }

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master", "orch", cwd, "master")
	if err := svc.Store.Update("qm-master", func(m *state.Manifest) {
		m.Agents = []state.AgentManifest{{
			Name:   "codex",
			Role:   "primary",
			CLI:    "/bin/sh",
			Window: 0,
		}}
		m.Extra = nil
	}); err != nil {
		t.Fatalf("update master manifest: %v", err)
	}

	result, err := svc.Spawn(t.Context(), "qm-master", SpawnOpts{Title: "wizard-worker"})
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

func TestSpawn_PrimaryOverride(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	counter := int64(6100)
	svc.Now = func() int64 { counter++; return counter }

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master", "orch", cwd, "master")

	master, err := svc.Store.Read("qm-master")
	if err != nil {
		t.Fatalf("read master: %v", err)
	}
	registry, err := WorkerSpawnRegistryWithBase(master, svc.Registry, &agent.ConfigOverrides{Primary: "codex"})
	if err != nil {
		t.Fatalf("WorkerSpawnRegistry: %v", err)
	}

	result, err := svc.Spawn(t.Context(), "qm-master", SpawnOpts{
		Title:    "primary-only",
		Registry: registry,
	})
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
		t.Fatalf("expected codex primary, got %+v", wm.Agents[0])
	}
}

func TestSpawn_FromNonMaster(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	createTestManifest(t, svc.Store, "qm-worker", "regular", t.TempDir(), "")

	_, err := svc.Spawn(t.Context(), "qm-worker", SpawnOpts{Title: "x"})
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

	dir, err := ensureRuntimeDir("qm-test-runtime")
	if err != nil {
		t.Fatalf("ensureRuntimeDir: %v", err)
	}
	defer removeRuntimeDir("qm-test-runtime")

	// Verify session-name file was written
	nameFile := dir + "/session-name"
	data, err := os.ReadFile(nameFile)
	if err != nil {
		t.Fatalf("read session-name: %v", err)
	}
	if strings.TrimSpace(string(data)) != "qm-test-runtime" {
		t.Errorf("session-name: got %q", string(data))
	}
}

func TestRemoveRuntimeDir(t *testing.T) {
	t.Parallel()

	dir, err := ensureRuntimeDir("qm-test-rm")
	if err != nil {
		t.Fatalf("ensureRuntimeDir: %v", err)
	}

	removeRuntimeDir("qm-test-rm")

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
	createTestManifest(t, svc.Store, "qm-parent", "master", t.TempDir(), "master")
	createTestManifest(t, svc.Store, "qm-child", "worker", t.TempDir(), "")

	// Set parent reference and register worker
	if err := svc.Store.Update("qm-child", func(m *state.Manifest) {
		m.SetExtra("parent_session", "qm-parent")
	}); err != nil {
		t.Fatalf("set parent: %v", err)
	}
	if err := svc.Store.AddWorker("qm-parent", "qm-child"); err != nil {
		t.Fatalf("add worker: %v", err)
	}

	runner.sessions["qm-child"] = true

	if err := svc.Delete(t.Context(), "qm-child"); err != nil {
		t.Fatalf("delete: %v", err)
	}

	// Verify worker was deregistered from parent
	workers, err := svc.Store.GetWorkers("qm-parent")
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	if len(workers) != 0 {
		t.Errorf("expected 0 workers, got %v", workers)
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

	if err := svc.Promote(t.Context(), "qm-ghost"); err == nil {
		t.Fatal("expected error for missing manifest")
	}
}

// ---------------------------------------------------------------------------
// Start with primary-only layout
// ---------------------------------------------------------------------------

func TestStart_StandaloneLayoutUsesPrimaryOnlyPane(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 7777 }

	result, err := svc.Start(t.Context(), StartOpts{
		Title: "layout-test",
		Cwd:   t.TempDir(),
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	// Verify session exists
	if !runner.sessions[result.SessionID] {
		t.Fatal("session not created")
	}

	assertPrimaryOnlyLayout(t, runner, result.SessionID)
	if got := runner.paneRoles[result.SessionID+":1.0"]; got != "" {
		t.Errorf("unexpected extra window role in 1.0: %q", got)
	}
}

// ---------------------------------------------------------------------------
// ---------------------------------------------------------------------------
// Continue with parent re-registration
// ---------------------------------------------------------------------------

func TestContinue_ReRegistersWithParent(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master2", "master", cwd, "master")
	createTestManifest(t, svc.Store, "qm-worker2", "worker", cwd, "")

	// Set parent reference
	if err := svc.Store.Update("qm-worker2", func(m *state.Manifest) {
		m.SetExtra("parent_session", "qm-master2")
	}); err != nil {
		t.Fatalf("set parent: %v", err)
	}

	_, err := svc.Continue(t.Context(), "qm-worker2")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}

	// Verify worker re-registered with parent
	workers, err := svc.Store.GetWorkers("qm-master2")
	if err != nil {
		t.Fatalf("get workers: %v", err)
	}
	if len(workers) != 1 || workers[0] != "qm-worker2" {
		t.Errorf("expected [qm-worker2], got %v", workers)
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
	if id != "qm-42" {
		t.Errorf("expected qm-42, got %s", id)
	}
}

func TestClaimSessionID_Collision(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)
	svc.Now = func() int64 { return 42 }
	svc.RandSuffix = func() int64 { return 99 }

	// Pre-create manifest for base ID to force collision
	if err := svc.Store.Create(state.Manifest{SessionID: "qm-42"}); err != nil {
		t.Fatalf("create collision manifest: %v", err)
	}

	id, err := svc.claimSessionID(t.Context(), state.Manifest{Title: "test", Cwd: "/tmp"})
	if err != nil {
		t.Fatalf("claimSessionID: %v", err)
	}
	if id != "qm-42-99" {
		t.Errorf("expected qm-42-99, got %s", id)
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

	if _, err := os.Stat(dir + "/codex-thread-id"); !os.IsNotExist(err) {
		t.Error("codex-thread-id should not exist without a codex primary")
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
		Title:     "test",
		Cwd:       t.TempDir(),
		ResumeIDs: map[string]string{"claude": "claude-sess-1"},
		Prompt:    "fix the bug",
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	// Verify resume IDs stored in manifest extra
	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if len(m.Agents) != 1 {
		t.Fatalf("expected 1 manifest agent, got %+v", m.Agents)
	}
	if got := manifestAgentResumeID(m.Agents, "primary"); got != "claude-sess-1" {
		t.Errorf("primary resume_id: got %q", got)
	}
	if got := m.ExtraString("claude_session_id"); got != "claude-sess-1" {
		t.Errorf("claude_session_id: got %q", got)
	}
	if got := m.ExtraString("initial_prompt"); got != "fix the bug" {
		t.Errorf("initial_prompt: got %q", got)
	}
}

func TestStart_OpenCodePrimaryPersistsResumeMetadata(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 8890 }

	opencodeCLI := filepath.Join(t.TempDir(), "opencode")
	if err := os.WriteFile(opencodeCLI, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("write opencode fixture: %v", err)
	}
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"opencode": {CLI: opencodeCLI, Model: "provider/model"},
		},
		Roles: agent.RolesConfig{
			Primary: &agent.RoleConfig{Agent: "opencode", Window: 0},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	svc.Registry = registry

	resumeID := "ses_0123456789abcdef"
	result, err := svc.Start(t.Context(), StartOpts{
		Title:     "opencode-primary",
		Cwd:       t.TempDir(),
		ResumeIDs: map[string]string{"opencode": resumeID},
		Prompt:    "inspect state",
	})
	if err != nil {
		t.Fatalf("start: %v", err)
	}

	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if got := manifestAgentResumeID(m.Agents, "primary"); got != resumeID {
		t.Fatalf("primary resume_id: got %q, want %q", got, resumeID)
	}
	if got := m.ExtraString("opencode_session_id"); got != resumeID {
		t.Fatalf("opencode_session_id: got %q, want %q", got, resumeID)
	}
	if got := runner.envVars[result.SessionID+":OPENCODE_SESSION_ID"]; got != resumeID {
		t.Fatalf("OPENCODE_SESSION_ID: got %q, want %q", got, resumeID)
	}
	data, err := os.ReadFile(filepath.Join(result.RuntimeDir, "opencode-session-id"))
	if err != nil {
		t.Fatalf("read opencode-session-id: %v", err)
	}
	if got := strings.TrimSpace(string(data)); got != resumeID {
		t.Fatalf("opencode-session-id file: got %q, want %q", got, resumeID)
	}
	wantConfigDir := state.OpenCodeConfigDir(svc.Store.Root())
	if got := runner.envVars[result.SessionID+":"+openCodeConfigDirEnv]; got != wantConfigDir {
		t.Fatalf("OPENCODE_CONFIG_DIR: got %q, want %q", got, wantConfigDir)
	}
	for _, file := range []string{
		filepath.Join(wantConfigDir, "plugins", "questmaster-opencode.js"),
		filepath.Join(wantConfigDir, "agents", agent.OpenCodeStandaloneAgentName+".md"),
	} {
		if _, err := os.Stat(file); err != nil {
			t.Fatalf("OpenCode launch did not install %s: %v", file, err)
		}
	}

	launch := findLaunchArgContaining(runner, opencodeCLI)
	for _, want := range []string{
		" --model 'provider/model'",
		" --agent 'questmaster-standalone'",
		" --session '" + resumeID + "'",
		" --prompt 'inspect state'",
	} {
		if !strings.Contains(launch, want) {
			t.Fatalf("OpenCode launch missing %q in %q", want, launch)
		}
	}
	if strings.Contains(launch, "developer_instructions") || strings.Contains(launch, "--append-system-prompt") {
		t.Fatalf("OpenCode launch used unsupported system prompt flag: %q", launch)
	}
	if strings.Contains(launch, "--dangerously-skip-permissions") {
		t.Fatalf("OpenCode TUI launch used unsupported permission flag: %q", launch)
	}
}

func TestStart_OpenCodeReasoningEffortRejectsOldVersion(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	opencodeCLI := filepath.Join(t.TempDir(), "opencode")
	if err := os.WriteFile(opencodeCLI, []byte("#!/bin/sh\nprintf '1.17.11\\n'\n"), 0o755); err != nil {
		t.Fatalf("write opencode fixture: %v", err)
	}
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"opencode": {CLI: opencodeCLI},
		},
		Roles: agent.RolesConfig{
			Primary: &agent.RoleConfig{Agent: "opencode", Window: 0},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	svc.Registry = registry

	if _, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), ReasoningEffort: "high"}); err == nil || !strings.Contains(err.Error(), "requires 1.17.15+") {
		t.Fatalf("Start(OpenCode 1.17.11, reasoning effort) = %v", err)
	}
	if len(runner.sessions) != 0 {
		t.Fatalf("old OpenCode version must fail before creating a tmux session: %+v", runner.sessions)
	}
}

func TestStart_OpenCodeReasoningEffortUsesInteractiveVariant(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	opencodeCLI := filepath.Join(t.TempDir(), "opencode")
	if err := os.WriteFile(opencodeCLI, []byte("#!/bin/sh\nprintf '1.17.15\\n'\n"), 0o755); err != nil {
		t.Fatalf("write opencode fixture: %v", err)
	}
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"opencode": {CLI: opencodeCLI},
		},
		Roles: agent.RolesConfig{
			Primary: &agent.RoleConfig{Agent: "opencode", Window: 0},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	svc.Registry = registry

	result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), Prompt: "inspect state", ReasoningEffort: "high"})
	if err != nil {
		t.Fatalf("Start(OpenCode, reasoning effort): %v", err)
	}
	launch := findLaunchArgContaining(runner, opencodeCLI)
	for _, want := range []string{
		"run --interactive",
		" --model 'openai/gpt-5.6-terra'",
		" --agent 'questmaster-standalone'",
		" --variant 'high'",
		" 'inspect state'",
	} {
		if !strings.Contains(launch, want) {
			t.Fatalf("OpenCode reasoning launch missing %q in %q", want, launch)
		}
	}
	configDir := state.OpenCodeConfigDir(svc.Store.Root())
	if got := runner.envVars[result.SessionID+":"+openCodeConfigDirEnv]; got != configDir {
		t.Fatalf("OPENCODE_CONFIG_DIR: got %q, want %q", got, configDir)
	}
	data, err := os.ReadFile(filepath.Join(configDir, "agents", agent.OpenCodeStandaloneAgentName+".md"))
	if err != nil {
		t.Fatalf("read role agent: %v", err)
	}
	if strings.Contains(string(data), "variant:") {
		t.Fatalf("per-spawn variant must not modify the shared role agent: %q", data)
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
			Primary: &agent.RoleConfig{Agent: "codex", Window: 0},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	svc.Registry = registry

	result, err := svc.Start(t.Context(), StartOpts{
		Title: "codex-primary",
		Cwd:   t.TempDir(),
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
	if m.Agents[0].Role != "primary" || m.Agents[0].Name != "codex" {
		t.Fatalf("primary agent: got %+v", m.Agents[0])
	}

	foundPrimaryCmd := false
	for _, call := range runner.calls {
		if len(call.args) >= 1 && call.args[0] == "respawn-pane" && strings.Contains(call.args[len(call.args)-1], codexCLI) {
			foundPrimaryCmd = true
			break
		}
	}
	if !foundPrimaryCmd {
		t.Fatal("expected primary pane to launch Codex command")
	}
}

func TestStart_CodexPrimaryMasterUsesDeveloperInstructions(t *testing.T) {
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

	wantConfig := "developer_instructions=" + strconv.Quote(agent.NewCodex(agent.AgentConfig{}).MasterPrompt())
	foundMasterCmd := false
	for _, call := range runner.calls {
		if len(call.args) >= 1 && call.args[0] == "respawn-pane" && strings.Contains(call.args[len(call.args)-1], codexCLI) {
			foundMasterCmd = true
			cmd := call.args[len(call.args)-1]
			if !strings.Contains(cmd, wantConfig) {
				t.Fatalf("master Codex command missing config %q in %q", wantConfig, cmd)
			}
			if !strings.HasSuffix(cmd, " 'triage the backlog'") {
				t.Fatalf("master Codex command should keep user prompt unchanged: %q", cmd)
			}
			if strings.Contains(cmd, "Task: triage the backlog") {
				t.Fatalf("master Codex command should not prefix prompt with task marker: %q", cmd)
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

func TestStart_WorkerPromptStaysFirstTurn(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 9901 }
	createTestManifest(t, svc.Store, "qm-master", "master", t.TempDir(), "master")

	task := "Deliver a short joke to the master session."
	if _, err := svc.Start(t.Context(), StartOpts{
		Title:    "jester",
		Cwd:      t.TempDir(),
		MasterID: "qm-master",
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
	if !strings.Contains(launch, agent.NewClaude(agent.AgentConfig{}).WorkerPrompt()) {
		t.Fatalf("expected built-in worker system prompt, got %q", launch)
	}
	if !strings.Contains(launch, "-- '"+task+"'") {
		t.Fatalf("expected worker prompt as positional first user turn, got %q", launch)
	}
	if strings.Count(launch, task) != 1 {
		t.Fatalf("expected task prompt once in launch command, got %q", launch)
	}
}

func TestStart_WorkerSystemBriefAppendedAfterWorkerPrompt(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 9903 }
	createTestManifest(t, svc.Store, "qm-master", "master", t.TempDir(), "master")

	task := "Use the maintenance branch if needed."
	if _, err := svc.Start(t.Context(), StartOpts{
		Title:       "legacy",
		Cwd:         t.TempDir(),
		MasterID:    "qm-master",
		SystemBrief: task,
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
		t.Fatal("expected worker launch command containing system brief")
	}
	wantSystem := agent.NewClaude(agent.AgentConfig{}).WorkerPrompt() + "\n\n" + task
	if !strings.Contains(launch, "--append-system-prompt '"+wantSystem+"'") {
		t.Fatalf("expected worker system brief appended after worker prompt, got %q", launch)
	}
	if strings.Contains(launch, "-- '"+task) {
		t.Fatalf("worker system brief must not appear as positional user turn, got %q", launch)
	}
}

func TestStart_WorkerPromptStaysFirstTurn_CodexPrimary(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	svc.Now = func() int64 { return 9902 }
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
	createTestManifest(t, svc.Store, "qm-codex-master", "master", t.TempDir(), "master")

	task := "Triage the backlog."
	if _, err := svc.Start(t.Context(), StartOpts{
		Title:    "codex-jester",
		Cwd:      t.TempDir(),
		MasterID: "qm-codex-master",
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
		t.Fatal("expected Codex worker launch command containing prompt")
	}
	wantConfig := "developer_instructions=" + strconv.Quote(agent.NewCodex(agent.AgentConfig{}).WorkerPrompt())
	if !strings.Contains(launch, wantConfig) {
		t.Fatalf("expected Codex worker prompt routed via developer_instructions, got %q", launch)
	}
	if !strings.HasSuffix(launch, " '"+task+"'") {
		t.Fatalf("Codex worker prompt must remain the first user turn, got %q", launch)
	}
	if strings.Count(launch, task) != 1 {
		t.Fatalf("expected Codex worker prompt once in launch command, got %q", launch)
	}
}

func TestStart_CodexReasoningEffortUsesEffectiveModel(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	counter := int64(9902)
	svc.Now = func() int64 { counter++; return counter }

	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"codex": {CLI: "/bin/sh"},
		},
		Roles: agent.RolesConfig{
			Primary: &agent.RoleConfig{Agent: "codex", Window: 0},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	svc.Registry = registry
	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-master", "master", cwd, "master")

	for _, effort := range []string{"max", "ultra"} {
		task := "default " + effort
		result, err := svc.Start(t.Context(), StartOpts{
			Title:           task,
			Cwd:             cwd,
			MasterID:        "qm-master",
			Prompt:          task,
			ReasoningEffort: effort,
		})
		if err != nil {
			t.Fatalf("Start(default Codex, %s): %v", effort, err)
		}
		launch := findLaunchArgContaining(runner, task)
		if !strings.Contains(launch, "--model 'gpt-5.6-terra'") || !strings.Contains(launch, `model_reasoning_effort="`+effort+`"`) {
			t.Fatalf("Codex %s launch = %q", effort, launch)
		}
		if !runner.sessions[result.SessionID] {
			t.Fatalf("expected tmux session %q", result.SessionID)
		}
	}

	started := len(runner.sessions)
	if _, err := svc.Start(t.Context(), StartOpts{Title: "old", Cwd: cwd, MasterID: "qm-master", Model: "gpt-5.4", ReasoningEffort: "max"}); err == nil || !strings.Contains(err.Error(), "supported: minimal, low, medium, high, xhigh") {
		t.Fatalf("Start(Codex gpt-5.4, max) = %v", err)
	}
	if len(runner.sessions) != started {
		t.Fatalf("invalid gpt-5.4 effort must fail before creating a tmux session: %+v", runner.sessions)
	}
}

func TestStart_PrimaryOnlyRegistry(t *testing.T) {
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
		Title: "solo",
		Cwd:   t.TempDir(),
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
	assertPrimaryOnlyLayout(t, runner, result.SessionID)
}

// ---------------------------------------------------------------------------
// Delete non-running session
// ---------------------------------------------------------------------------

func TestDelete_NotRunning(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	createTestManifest(t, svc.Store, "qm-stopped", "stopped", t.TempDir(), "")

	// Should succeed (KillSession returns nil for absent sessions)
	if err := svc.Delete(t.Context(), "qm-stopped"); err != nil {
		t.Fatalf("delete stopped: %v", err)
	}

	// Manifest should be gone
	if _, err := svc.Store.Read("qm-stopped"); err == nil {
		t.Error("manifest should be deleted")
	}
}

// Test Continue with bad cwd (falls back to getwd)
func TestContinue_BadCwd(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	createTestManifest(t, svc.Store, "qm-badcwd", "test", "/nonexistent/path/definitely", "")

	_, err := svc.Continue(t.Context(), "qm-badcwd")
	// Should succeed (falls back to getwd when cwd doesn't exist)
	if err != nil {
		t.Fatalf("continue with bad cwd: %v", err)
	}
}

func TestContinue_PersistsPiResumeFromActivityAndUsesSessionFlag(t *testing.T) {
	svc, runner := setupService(t)
	cwd := t.TempDir()
	sessionID := "qm-pi-activity-resume"
	resumeID := "019dee69-5623-75c9-9317-04bf7f94e92b"
	writePiResumeState(t, svc.Store, sessionID, resumeID)

	if err := svc.Store.Create(state.Manifest{
		SessionID: sessionID,
		Title:     "pi-activity",
		Cwd:       cwd,
		AgentPath: "/usr/bin",
		Agents: []state.AgentManifest{
			{Name: "pi", Role: "primary", CLI: "/usr/bin/pi", Window: 1},
		},
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	if _, err := svc.Continue(t.Context(), sessionID); err != nil {
		t.Fatalf("continue: %v", err)
	}

	launch := findLaunchArgContaining(runner, "/usr/bin/pi")
	if !strings.Contains(launch, " --session '"+resumeID+"'") {
		t.Fatalf("continued Pi command missing --session UUID: %q", launch)
	}
	if got := runner.envVars[sessionID+":PI_SESSION_ID"]; got != resumeID {
		t.Fatalf("PI_SESSION_ID: got %q, want %q", got, resumeID)
	}

	m, err := svc.Store.Read(sessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if got := manifestAgentResumeID(m.Agents, "primary"); got != resumeID {
		t.Fatalf("primary resume_id: got %q, want %q", got, resumeID)
	}
	if got := m.ExtraString("pi_session_id"); got != resumeID {
		t.Fatalf("pi_session_id: got %q, want %q", got, resumeID)
	}
}

func TestContinue_UsesAgentManifestResumeIDs(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	cwd := t.TempDir()

	if err := svc.Store.Create(state.Manifest{
		SessionID: "qm-agents",
		Title:     "agent-manifest",
		Cwd:       cwd,
		Agents: []state.AgentManifest{
			{Name: "claude", Role: "primary", CLI: "/usr/bin/claude", ResumeID: "claude-resume", Window: 1},
		},
		AgentPath: "/usr/bin",
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	if _, err := svc.Continue(t.Context(), "qm-agents"); err != nil {
		t.Fatalf("continue: %v", err)
	}
	if got := runner.envVars["qm-agents:CLAUDE_SESSION_ID"]; got != "claude-resume" {
		t.Fatalf("CLAUDE_SESSION_ID: got %q", got)
	}
}

func TestContinue_OpenCodeUsesExtraResumeIDAndAgentFlag(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	cwd := t.TempDir()
	sessionID := "qm-opencode-resume"
	runtimeDir := filepath.Join("/tmp", sessionID)
	_ = os.RemoveAll(runtimeDir)
	t.Cleanup(func() { _ = os.RemoveAll(runtimeDir) })

	opencodeCLI := filepath.Join(cwd, "opencode")
	if err := os.WriteFile(opencodeCLI, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatalf("write opencode fixture: %v", err)
	}
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"opencode": {CLI: opencodeCLI, Model: "provider/model"},
		},
		Roles: agent.RolesConfig{
			Primary: &agent.RoleConfig{Agent: "opencode", Window: 0},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	svc.Registry = registry

	resumeID := "ses_0123456789abcdef"
	m := state.Manifest{
		SessionID: sessionID,
		Title:     "opencode-resume",
		Cwd:       cwd,
		AgentPath: filepath.Dir(opencodeCLI),
		Agents: []state.AgentManifest{
			{Name: "opencode", Role: "primary", CLI: opencodeCLI, Window: 1},
		},
	}
	m.SetExtra("opencode_session_id", resumeID)
	if err := svc.Store.Create(m); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	if _, err := svc.Continue(t.Context(), sessionID); err != nil {
		t.Fatalf("continue: %v", err)
	}

	launch := findLaunchArgContaining(runner, opencodeCLI)
	for _, want := range []string{
		" --model 'provider/model'",
		" --agent 'questmaster-standalone'",
		" --session '" + resumeID + "'",
	} {
		if !strings.Contains(launch, want) {
			t.Fatalf("OpenCode continue launch missing %q in %q", want, launch)
		}
	}
	if strings.Contains(launch, "--continue") {
		t.Fatalf("OpenCode continue must use --session, got %q", launch)
	}
	if strings.Contains(launch, "--dangerously-skip-permissions") {
		t.Fatalf("OpenCode continue TUI launch used unsupported permission flag: %q", launch)
	}
	if got := runner.envVars[sessionID+":OPENCODE_SESSION_ID"]; got != resumeID {
		t.Fatalf("OPENCODE_SESSION_ID: got %q, want %q", got, resumeID)
	}
	if got, want := runner.envVars[sessionID+":"+openCodeConfigDirEnv], state.OpenCodeConfigDir(svc.Store.Root()); got != want {
		t.Fatalf("OPENCODE_CONFIG_DIR: got %q, want %q", got, want)
	}
	data, err := os.ReadFile(filepath.Join(runtimeDir, "opencode-session-id"))
	if err != nil {
		t.Fatalf("read opencode-session-id: %v", err)
	}
	if got := strings.TrimSpace(string(data)); got != resumeID {
		t.Fatalf("opencode-session-id file: got %q, want %q", got, resumeID)
	}

	updated, err := svc.Store.Read(sessionID)
	if err != nil {
		t.Fatalf("read updated manifest: %v", err)
	}
	if got := manifestAgentResumeID(updated.Agents, "primary"); got != resumeID {
		t.Fatalf("primary resume_id: got %q, want %q", got, resumeID)
	}
	if got := updated.ExtraString("opencode_session_id"); got != resumeID {
		t.Fatalf("opencode_session_id: got %q, want %q", got, resumeID)
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
			Primary: &agent.RoleConfig{Agent: "claude", Window: -1},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry(swapped): %v", err)
	}
	svc.Registry = swappedRegistry

	if err := svc.Store.Create(state.Manifest{
		SessionID: "qm-manifest",
		Title:     "manifest-source",
		Cwd:       cwd,
		Agents: []state.AgentManifest{
			{Name: "codex", Role: "primary", CLI: codexCLI, ResumeID: "codex-primary", Window: 1},
		},
		AgentPath: "/usr/bin",
	}); err != nil {
		t.Fatalf("create manifest: %v", err)
	}

	if _, err := svc.Continue(t.Context(), "qm-manifest"); err != nil {
		t.Fatalf("continue: %v", err)
	}

	m, err := svc.Store.Read("qm-manifest")
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if len(m.Agents) != 1 {
		t.Fatalf("expected 1 agent, got %+v", m.Agents)
	}
	if m.Agents[0].Role != "primary" || m.Agents[0].Name != "codex" || m.Agents[0].CLI != codexCLI {
		t.Fatalf("primary manifest agent: got %+v", m.Agents[0])
	}

	var sawCodexPrimary bool
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
	}
	if !sawCodexPrimary {
		t.Fatal("expected Codex primary launch command from manifest agent")
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

// Test Continue stopped master with primary-only layout
func TestContinue_StoppedMasterPrimaryOnlyLayout(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	cwd := t.TempDir()
	createTestManifest(t, svc.Store, "qm-msb", "master-sb", cwd, "master")

	result, err := svc.Continue(t.Context(), "qm-msb")
	if err != nil {
		t.Fatalf("continue: %v", err)
	}
	if !result.Master {
		t.Fatal("expected master=true")
	}
	if !runner.sessions["qm-msb"] {
		t.Fatal("session not recreated")
	}
	assertPrimaryOnlyLayout(t, runner, "qm-msb")
}

// Test Start creates unique IDs on collision
func TestStart_IDCollision(t *testing.T) {
	t.Parallel()
	svc, _ := setupService(t)

	// Pre-create manifest for base ID to force collision via Store.Create.
	if err := svc.Store.Create(state.Manifest{SessionID: "qm-42"}); err != nil {
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
	if result.SessionID == "qm-42" {
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
	got := runtimeDir("qm-test-123")
	if !strings.HasSuffix(got, "qm-test-123") {
		t.Errorf("expected path ending in qm-test-123, got %q", got)
	}
}

// Test launch workspace successful path directly.
func TestLaunchWorkspace_Success(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	runner.sessions["qm-lw"] = true

	if err := svc.launchAppWorkspace(t.Context(), "qm-lw", "/tmp", false, false, launchCmds("echo claude")); err != nil {
		t.Fatalf("launch workspace: %v", err)
	}
	assertPrimaryOnlyLayout(t, runner, "qm-lw")
}

func TestLaunchWorkspace_PrimaryStartsAfterRoleAssignment(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)
	runner.sessions["qm-lw3"] = true

	primaryCmd := "echo claude"
	if err := svc.launchAppWorkspace(t.Context(), "qm-lw3", "/tmp", false, false, launchCmds(primaryCmd)); err != nil {
		t.Fatalf("launch workspace: %v", err)
	}

	roleOptionIdx := -1
	primaryRespawnIdx := -1

	for i, call := range runner.calls {
		if len(call.args) == 0 {
			continue
		}
		switch call.args[0] {
		case "set-option":
			if flagVal(call.args, "-t") == "qm-lw3:0.0" && call.args[len(call.args)-2] == tmux.PaneRoleOption {
				roleOptionIdx = i
			}
		case "respawn-pane":
			if flagVal(call.args, "-t") == "qm-lw3:0.0" {
				primaryRespawnIdx = i
				if !strings.Contains(strings.Join(call.args, " "), primaryCmd) {
					t.Fatalf("expected primary command launched via respawn-pane: %v", call.args)
				}
			}
		}
	}

	if roleOptionIdx == -1 {
		t.Fatalf("expected primary role assignment, calls=%v", runner.calls)
	}
	if primaryRespawnIdx == -1 {
		t.Fatalf("expected respawn-pane launch for primary pane, calls=%v", runner.calls)
	}
	if primaryRespawnIdx <= roleOptionIdx {
		t.Fatalf("primary launched before role assignment completed: role=%d respawn=%d calls=%v", roleOptionIdx, primaryRespawnIdx, runner.calls)
	}
}

// ---------------------------------------------------------------------------
// setResumeEnv
// ---------------------------------------------------------------------------

func TestSetResumeEnv(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["qm-env"] = true

	resume := map[agent.Role]resumeInfo{
		agent.RolePrimary: {
			provider: agent.NewClaude(agent.AgentConfig{}),
			resumeID: "claude-1",
		},
	}
	if err := svc.setResumeEnv(t.Context(), "qm-env", resume); err != nil {
		t.Fatalf("setResumeEnv: %v", err)
	}

	if runner.envVars["qm-env:CLAUDE_SESSION_ID"] != "claude-1" {
		t.Errorf("CLAUDE_SESSION_ID: got %q", runner.envVars["qm-env:CLAUDE_SESSION_ID"])
	}
}

func TestSetResumeEnv_Empty(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["qm-env2"] = true

	if err := svc.setResumeEnv(t.Context(), "qm-env2", map[agent.Role]resumeInfo{}); err != nil {
		t.Fatalf("setResumeEnv: %v", err)
	}

	// Should not set vars for empty IDs
	if _, ok := runner.envVars["qm-env2:CLAUDE_SESSION_ID"]; ok {
		t.Error("CLAUDE_SESSION_ID should not be set for empty ID")
	}
}

// ---------------------------------------------------------------------------
// setCleanupHook
// ---------------------------------------------------------------------------

func TestSetCleanupHook(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.sessions["qm-hook"] = true

	if err := svc.setCleanupHook(t.Context(), "qm-hook"); err != nil {
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
	runner.sessions["qm-vis"] = true

	if err := svc.setCleanupHook(t.Context(), "qm-vis"); err != nil {
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
	if !strings.Contains(hookCmd, "hook_session_name") {
		t.Error("hook must pass the closed session name to cleanup.sh")
	}
	if !strings.Contains(hookCmd, "/tmp/#{q:hook_session_name}/cleanup.sh") {
		t.Error("hook must resolve cleanup.sh from the closed session name")
	}
	if strings.Contains(hookCmd, "/tmp/qm-vis/cleanup.sh") {
		t.Error("hook must not hardcode the owning session cleanup path")
	}

	// Read the generated cleanup script and verify its content.
	scriptPath := filepath.Join("/tmp", "qm-vis", "cleanup.sh")
	script, err := os.ReadFile(scriptPath)
	if err != nil {
		t.Fatalf("read cleanup script: %v", err)
	}
	s := string(script)

	// Script must reference the session ID in manifest paths and rm -rf.
	if !strings.Contains(s, "qm-vis") {
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
// state root contains spaces (QUESTMASTER_STATE_ROOT is user-configurable).
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
	runner.sessions["qm-sp"] = true
	client := tmux.NewClient(runner)
	svc := NewService(store, client, "")

	if err := svc.setCleanupHook(t.Context(), "qm-sp"); err != nil {
		t.Fatalf("setCleanupHook: %v", err)
	}

	// Read the generated cleanup script and verify the state root is quoted.
	scriptPath := filepath.Join("/tmp", "qm-sp", "cleanup.sh")
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
	runner.sessions["qm-ap"] = true
	client := tmux.NewClient(runner)
	svc := NewService(store, client, "")

	if err := svc.setCleanupHook(t.Context(), "qm-ap"); err != nil {
		t.Fatalf("setCleanupHook: %v", err)
	}

	// Read the script and verify it's syntactically valid shell.
	scriptPath := filepath.Join("/tmp", "qm-ap", "cleanup.sh")
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

func TestLaunchWorkspace_ErrorOnRespawn(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.fn = func(_ context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "respawn-pane" {
			return "", &tmux.ExitError{Code: 1}
		}
		return runner.defaultHandler(t.Context(), args...)
	}

	runner.sessions["qm-werr"] = true

	err := svc.launchAppWorkspace(t.Context(), "qm-werr", "/tmp", false, false, launchCmds("claude"))
	if err == nil {
		t.Fatal("expected error from launch workspace")
	}
}

func TestLaunchWorkspace_ErrorOnPrimaryRespawn(t *testing.T) {
	t.Parallel()
	svc, runner := setupService(t)

	runner.fn = func(ctx context.Context, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "respawn-pane" && flagVal(args, "-t") == "qm-wresp:0.0" {
			return "", &tmux.ExitError{Code: 1}
		}
		return runner.defaultHandler(ctx, args...)
	}

	runner.sessions["qm-wresp"] = true

	err := svc.launchAppWorkspace(t.Context(), "qm-wresp", "/tmp", false, false, launchCmds("claude"))
	if err == nil {
		t.Fatal("expected error from launch workspace primary respawn")
	}
	if !strings.Contains(err.Error(), "session primary pane") {
		t.Fatalf("expected primary pane context in error, got %v", err)
	}
}

// ---------------------------------------------------------------------------
// orderedManifestAgents
// ---------------------------------------------------------------------------

func TestOrderedManifestAgents_RejectsLegacyOnlyManifest(t *testing.T) {
	t.Parallel()

	// A pre-agent-agnostic-rename manifest: bash wrote only the per-provider
	// keys into Extra, never populated the canonical Agents array. Pass 2
	// removed the UnmarshalJSON migration that used to synthesize Agents
	// entries from these fields, so continuing such a session must fail
	// loudly rather than silently launching with no primary.
	raw := `{"session_id":"qm-legacy","claude_bin":"/usr/bin/claude","codex_bin":"/usr/bin/codex","claude_session_id":"abc","codex_thread_id":"xyz"}`

	var m state.Manifest
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(m.Agents) != 0 {
		t.Fatalf("expected empty Agents after Pass 2 migration removal, got %+v", m.Agents)
	}

	_, err := orderedManifestAgents(m)
	if err == nil {
		t.Fatal("expected error for manifest missing a primary agent, got nil")
	}
	if !strings.Contains(err.Error(), "missing a primary agent") {
		t.Fatalf("unexpected error: %v", err)
	}
}
