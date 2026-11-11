//go:build linux || darwin

package session

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

func TestStartShellSession(t *testing.T) {
	t.Parallel()

	svc, runner := setupService(t)
	setMissingAgentRegistry(t, svc)
	svc.Now = func() int64 { return 501 }

	result, err := svc.Start(t.Context(), StartOpts{
		Title: "plain",
		Cwd:   t.TempDir(),
		Shell: true,
	})
	if err != nil {
		t.Fatalf("Start shell: %v", err)
	}

	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatalf("read manifest: %v", err)
	}
	if len(m.Agents) != 0 {
		t.Fatalf("shell manifest agents = %+v, want none", m.Agents)
	}
	if m.SessionType != "" {
		t.Fatalf("shell session_type = %q, want empty", m.SessionType)
	}
	pane := runner.sessionPane(result.SessionID)
	if got := runner.paneRoles[runner.targetKey(pane)]; got != tmux.RoleShell {
		t.Fatalf("pane role = %q, want shell", got)
	}
	if runner.hasCall("split-window") {
		t.Fatalf("shell session should not split panes, calls=%v", runner.calls)
	}

	envIdx := callIndex(runner, func(args []string) bool {
		return len(args) >= 5 && args[0] == "set-environment" && flagVal(args, "-t") == tmux.SessionTarget(result.SessionID) && args[len(args)-2] == state.SessionEnv
	})
	respawnIdx := callIndex(runner, func(args []string) bool {
		return len(args) > 0 && args[0] == "respawn-pane" && flagVal(args, "-t") == pane
	})
	if envIdx < 0 || respawnIdx < 0 {
		t.Fatalf("expected session env and shell respawn, calls=%v", runner.calls)
	}
	if envIdx > respawnIdx {
		t.Fatalf("%s set after shell respawn: env=%d respawn=%d", state.SessionEnv, envIdx, respawnIdx)
	}
	got := runner.calls[respawnIdx].args[len(runner.calls[respawnIdx].args)-1]
	if !strings.HasPrefix(got, "cd -- ") || !strings.HasSuffix(got, " || exit 1; "+loginShellCommand()) {
		t.Fatalf("shell respawn command = %q, want a cd into the session directory, then %q", got, loginShellCommand())
	}
}

func TestStartShellSessionRejectsAgentOnlyOptions(t *testing.T) {
	t.Parallel()

	tests := map[string]StartOpts{
		"worker": {Shell: true, MasterID: "qm-master"},
		"prompt": {Shell: true, Prompt: "do work"},
		"system": {Shell: true, SystemBrief: "brief"},
	}
	for name, opts := range tests {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			svc, _ := setupService(t)
			opts.Cwd = t.TempDir()

			_, err := svc.Start(t.Context(), opts)
			if err == nil || !strings.Contains(err.Error(), "start --shell") {
				t.Fatalf("Start shell conflict error = %v, want start --shell guard", err)
			}
		})
	}
}

func setMissingAgentRegistry(t *testing.T, svc *Service) {
	t.Helper()
	missing := filepath.Join(t.TempDir(), "missing-claude")
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"claude": {CLI: missing},
		},
		Roles: agent.RolesConfig{
			Agent: &agent.RoleConfig{Agent: "claude", Window: -1},
		},
	})
	if err != nil {
		t.Fatalf("NewRegistry: %v", err)
	}
	svc.Registry = registry
}

func TestStartAssignsOrPersistsSessionClass(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name  string
		class string
		index int
		want  string
	}{
		{name: "automatic", index: 6, want: "bard"},
		{name: "explicit", class: " Ranger ", want: "ranger"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			svc, runner := setupService(t)
			svc.RandClassIndex = func(n int) int {
				if n != 11 {
					t.Fatalf("random class choices = %d, want 11", n)
				}
				return tt.index
			}
			result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), Class: tt.class})
			if err != nil {
				t.Fatalf("Start(): %v", err)
			}
			manifest, err := svc.Store.Read(result.SessionID)
			if err != nil {
				t.Fatal(err)
			}
			if got := manifest.DisplayClass(); got != tt.want {
				t.Fatalf("DisplayClass() = %q, want %q", got, tt.want)
			}
			name := strings.ToUpper(tt.want[:1]) + tt.want[1:]
			if launch := findLaunchArgContaining(runner, "exec '/bin/sh'"); !strings.Contains(launch, "Your session class is the "+name+". Let its temperament") {
				t.Fatalf("master launch command missing %s class voice: %q", name, launch)
			}
		})
	}
}

func TestStartDefaultClassCountsOnlyLiveMasters(t *testing.T) {
	t.Parallel()

	svc, runner := setupService(t)
	for id, class := range map[string]string{
		"qm-live-paladin":  "paladin",
		"qm-live-wizard":   "wizard",
		"qm-stopped-rogue": "rogue",
		"qm-live-shell":    "barbarian",
		"qm-live-worker":   "druid",
	} {
		manifest := state.Manifest{TmuxServer: "questmaster", SessionID: id, Display: &state.DisplayMetadata{Class: class}}
		switch id {
		case "qm-live-paladin", "qm-live-wizard", "qm-stopped-rogue":
			manifest.Agents = []state.AgentManifest{{Name: "codex", Role: "agent"}}
		case "qm-live-worker":
			manifest.Agents = []state.AgentManifest{{Name: "codex", Role: "agent"}}
			manifest.SetExtra("parent_session", "qm-live-paladin")
		}
		if err := svc.Store.Create(manifest); err != nil {
			t.Fatal(err)
		}
		if id != "qm-stopped-rogue" {
			runner.sessions[id] = true
		}
	}
	svc.RandClassIndex = func(n int) int {
		if n != 9 {
			t.Fatalf("least-used classes = %d, want 9", n)
		}
		return 1
	}

	result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir()})
	if err != nil {
		t.Fatalf("Start(): %v", err)
	}
	manifest, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	if got := manifest.DisplayClass(); got != "barbarian" {
		t.Fatalf("assigned class = %q, want barbarian from unused classes", got)
	}
}

func TestStartRejectsInvalidOrInapplicableSessionClass(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name    string
		opts    StartOpts
		wantErr string
	}{
		{name: "invalid", opts: StartOpts{Class: "unknown"}, wantErr: "paladin, wizard, druid, barbarian, rogue, cleric, bard, ranger, necromancer, sorcerer, fighter"},
		{name: "shell", opts: StartOpts{Shell: true, Class: "wizard"}, wantErr: "shell sessions"},
		{name: "worker", opts: StartOpts{MasterID: "qm-master", Class: "wizard"}, wantErr: "workers inherit"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			svc, _ := setupService(t)
			tt.opts.Cwd = t.TempDir()
			if _, err := svc.Start(t.Context(), tt.opts); err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("Start() error = %v, want %q", err, tt.wantErr)
			}
		})
	}
}

func callIndex(runner *mockRunner, match func([]string) bool) int {
	for i, call := range runner.calls {
		if match(call.args) {
			return i
		}
	}
	return -1
}

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
	if err := store.Create(state.Manifest{TmuxServer: "questmaster", SessionID: "qm-100"}); err != nil {
		t.Fatal(err)
	}

	runner := &testRunner{fn: func(_ context.Context, args ...string) (string, error) {
		if args[0] == "show-options" {
			return tmuxconfig.RootMarker(store.Root(), "questmaster"), nil
		}
		if args[0] == "has-session" {
			return "", &tmux.ExitError{Code: 1} // no tmux session exists
		}
		if args[0] == "new-session" {
			return "%1", nil
		}
		return "", nil // all other tmux commands succeed
	}}
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"claude": {CLI: "/bin/sh"},
			"codex":  {CLI: "/bin/sh"},
		},
		Roles: agent.RolesConfig{
			Agent: &agent.RoleConfig{Agent: "claude", Window: -1},
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
		Title:    "rollback-worker",
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
	if _, err := os.Stat(state.NewRuntimeDir(svc.Store.Root(), sessionID)); !os.IsNotExist(err) {
		t.Fatalf("runtime dir should be removed after rollback, stat err=%v", err)
	}
	if _, err := os.Stat(state.SessionStateDir(stateRoot, sessionID)); !os.IsNotExist(err) {
		t.Fatalf("session state dir should be removed after rollback, stat err=%v", err)
	}
	// The failed new-session created nothing; a session by that name belongs to
	// someone else.
	if runner.hasCall("kill-session") {
		t.Fatalf("rollback killed a tmux session this Start did not create: %v", runner.calls)
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
		Title:    "ghost-worker",
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
	if _, err := os.Stat(state.NewRuntimeDir(svc.Store.Root(), sessionID)); !os.IsNotExist(err) {
		t.Fatalf("runtime dir should be removed after rollback, stat err=%v", err)
	}
	if _, err := os.Stat(state.SessionStateDir(stateRoot, sessionID)); !os.IsNotExist(err) {
		t.Fatalf("session state dir should be removed after rollback, stat err=%v", err)
	}
}

func TestStart_MissingAgentBinaryErrorNamesOverrideAndFallback(t *testing.T) {
	t.Setenv("PATH", "/nonexistent")
	tmuxtest.StubQuestmaster(t)
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
	tmuxtest.StubQuestmaster(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("PI_BIN", "")

	binDir := t.TempDir()
	piPath := filepath.Join(binDir, "pi")
	if err := os.WriteFile(piPath, []byte("#!/bin/sh\nexit 0\n"), 0o755); err != nil {
		t.Fatalf("write pi fixture: %v", err)
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

	store, err := state.NewStore(shortTempDir(t))
	if err != nil {
		t.Fatal(err)
	}
	runner := newMockRunner()
	runner.ownerMarker = tmuxconfig.RootMarker(store.Root(), "questmaster")
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{
			"pi": {CLI: "pi"},
		},
		Roles: agent.RolesConfig{
			Agent: &agent.RoleConfig{Agent: "pi", Window: -1},
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
	if len(m.Agents) != 1 || m.Agents[0].CLI != piPath {
		t.Fatalf("manifest agent CLI = %+v, want %q", m.Agents, piPath)
	}
	if !pathContainsDir(m.AgentPath, binDir) {
		t.Fatalf("manifest agent path %q does not contain %q", m.AgentPath, binDir)
	}
	if got := runner.envVars[result.SessionID+":PATH"]; !pathContainsDir(got, binDir) {
		t.Fatalf("tmux PATH %q does not contain %q", got, binDir)
	}
	launch := findLaunchArgContaining(runner, piPath)
	if launch == "" {
		t.Fatalf("agent launch command did not include resolved pi path %q", piPath)
	}
	if !strings.Contains(launch, "export PATH=") || !strings.Contains(launch, binDir) {
		t.Fatalf("agent launch command did not export login-derived PATH: %q", launch)
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
