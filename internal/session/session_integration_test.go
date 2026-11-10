//go:build linux || darwin

package session

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

// A private tmux server and its panes are OS processes; these waits are
// watchdogs for their observable state, not latency assertions.
const sessionIntegrationWaitTimeout = 30 * time.Second

// Deleting a stopped session must not kill a live session whose name starts
// with it. A bare kill-session -t qm-123 kills qm-123-456.
func TestIntegrationDeleteStoppedBaseKeepsSibling(t *testing.T) {
	t.Parallel()
	tmuxtest.RequireIntegration(t)
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	base := uniqueRuntimeSessionID(t, "qm-del")
	sibling := base + "-456"
	if err := store.Create(state.Manifest{TmuxServer: "questmaster", SessionID: base, Cwd: t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	runner := tmuxtest.NewRunner(t)
	if _, err := runner.Run(t.Context(), "new-session", "-d", "-s", sibling, "sleep 60"); err != nil {
		t.Fatalf("start sibling: %v", err)
	}
	client := tmux.NewClient(runner)
	svc := &Service{Store: store, Client: client}

	if _, err := svc.Delete(t.Context(), base); err != nil {
		t.Fatalf("Delete(%s): %v", base, err)
	}

	alive, err := client.HasSession(t.Context(), sibling)
	if err != nil {
		t.Fatalf("HasSession(%s): %v", sibling, err)
	}
	if !alive {
		t.Fatalf("deleting stopped %s killed live %s", base, sibling)
	}
	if _, err := store.Read(base); err == nil {
		t.Fatalf("manifest for %s still exists after Delete", base)
	}
}

// Two Continue calls race on one stopped session. One creates it, and the
// other must leave it running. Unserialized, both saw the session stopped, the
// second new-session failed as a duplicate, and its rollback killed the
// session the first had just created.
func TestIntegrationConcurrentContinueKeepsWinner(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	t.Setenv("SHELL", "/bin/sh") // the shell pane starts a login shell
	store, named := privateCleanupServer(t)
	id := uniqueRuntimeSessionID(t, "qm-race")
	if err := store.Create(state.Manifest{TmuxServer: "test_named", SessionID: id, Cwd: t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	runner := newCheckBarrier(named, 2, time.Second)
	client := tmux.NewClient(runner)
	svc := &Service{Store: store, Client: client, Router: tmuxroute.New(store, map[string]*tmux.Client{"test_named": client}, func() string { return "test_named" }, nil)}

	type outcome struct {
		result ContinueResult
		err    error
	}
	outcomes := make(chan outcome, 2)
	for range 2 {
		go func() {
			result, err := svc.Continue(t.Context(), id)
			outcomes <- outcome{result, err}
		}()
	}
	reattached := 0
	for range 2 {
		o := <-outcomes
		if o.err != nil {
			t.Errorf("Continue: %v", o.err)
		}
		if o.result.Reattach {
			reattached++
		}
	}

	alive, err := client.HasSession(t.Context(), id)
	if err != nil {
		t.Fatal(err)
	}
	if !alive {
		t.Fatalf("no session survived two concurrent Continue calls for %s", id)
	}
	if reattached != 1 {
		t.Errorf("%d of 2 Continue calls reattached, want 1", reattached)
	}
}

// checkBarrier holds each has-session until n of them have arrived or wait
// has passed. Callers that nothing serializes therefore all see the session in
// the same state; serialized callers only lose the wait.
type checkBarrier struct {
	tmux.Runner
	n       int
	wait    time.Duration
	mu      sync.Mutex
	arrived int
	release chan struct{}
}

func newCheckBarrier(runner tmux.Runner, n int, wait time.Duration) *checkBarrier {
	return &checkBarrier{Runner: runner, n: n, wait: wait, release: make(chan struct{})}
}

func (b *checkBarrier) Run(ctx context.Context, args ...string) (string, error) {
	if len(args) > 0 && args[0] == "has-session" {
		b.mu.Lock()
		b.arrived++
		if b.arrived == b.n {
			close(b.release)
		}
		b.mu.Unlock()
		select {
		case <-b.release:
		case <-time.After(b.wait):
		}
	}
	return b.Runner.Run(ctx, args...)
}

// tmux runs the session-closed hook of a session that is still alive, so the
// hook must find the closed session's script by name. The state root holds a
// character special to each parser the hook text passes (tmux's command
// parser, run-shell's formats, sh): the closed session's private runtime
// directory goes, the live one's stays.
func TestIntegrationSessionClosedHookCleansTheClosedSession(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	t.Setenv("SHELL", "/bin/sh")
	store, runner := privateCleanupServer(t, filepath.Join(shortTempDir(t), `a b'c"d$e#Sf\g`))
	client := tmux.NewClient(runner)
	svc := NewService(store, client, "")
	svc.Router = tmuxroute.New(store, map[string]*tmux.Client{"test_named": client}, func() string { return "test_named" }, nil)
	start := func(now int64) StartResult {
		t.Helper()
		svc.Now = func() int64 { return now }
		result, err := svc.Start(t.Context(), StartOpts{Shell: true, Cwd: t.TempDir()})
		if err != nil {
			t.Fatalf("Start: %v", err)
		}
		return result
	}
	closed := start(1700000201)
	live := start(1700000202)

	if err := svc.Client.KillSession(t.Context(), closed.SessionID); err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(sessionIntegrationWaitTimeout)
	for {
		if _, err := os.Lstat(closed.RuntimeDir); errors.Is(err, os.ErrNotExist) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("session-closed hook did not remove %s", closed.RuntimeDir)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := os.Stat(filepath.Join(live.RuntimeDir, "session-name")); err != nil {
		t.Fatalf("live session's runtime dir touched: %v", err)
	}
}

// baseIndexOneRunner is a private server whose windows and panes count from 1,
// set by its first commands. Questmaster must not assume index 0.
func baseIndexOneRunner(t *testing.T) *tmuxtest.Runner {
	t.Helper()
	runner := tmuxtest.NewRunner(t)
	if _, err := runner.Run(t.Context(),
		"start-server", ";",
		"set-option", "-g", "exit-empty", "off", ";",
		"set-option", "-g", "base-index", "1", ";",
		"set-option", "-g", "pane-base-index", "1",
	); err != nil {
		t.Fatalf("configure private server: %v", err)
	}
	return runner
}

// fakeAgentService returns a service whose Claude binary is script, on runner.
func fakeAgentService(t *testing.T, runner tmux.Runner, script string) *Service {
	t.Helper()
	cli := filepath.Join(t.TempDir(), "fake-claude")
	if err := os.WriteFile(cli, []byte("#!/bin/sh\n"+script), 0o755); err != nil {
		t.Fatal(err)
	}
	store, err := state.NewStore(shortTempDir(t))
	if err != nil {
		t.Fatal(err)
	}
	registry, err := agent.NewRegistry(&agent.Config{
		Agents: map[string]agent.AgentConfig{"claude": {CLI: cli}},
		Roles:  agent.RolesConfig{Agent: &agent.RoleConfig{Agent: "claude", Window: -1}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := runner.Run(t.Context(), "set-option", "-g", "@questmaster_root", tmuxconfig.RootMarker(store.Root(), "questmaster")); err != nil {
		t.Fatal(err)
	}
	svc := NewService(store, tmux.NewClient(runner), "", registry)
	svc.CLIResolver = func(string) (string, error) { return "true", nil }
	return svc
}

type livePane struct{ id, window, pane, dead, role string }

func sessionPanes(t *testing.T, runner tmux.Runner, sessionID string) []livePane {
	t.Helper()
	out, err := runner.Run(t.Context(), "list-panes", "-s", "-t", tmux.SessionTarget(sessionID),
		"-F", "#{pane_id} #{window_index} #{pane_index} #{pane_dead} #{@party_role}")
	if err != nil {
		t.Fatalf("list panes of %s: %v", sessionID, err)
	}
	var panes []livePane
	for _, line := range strings.Split(out, "\n") {
		fields := strings.Fields(line)
		for len(fields) < 5 {
			fields = append(fields, "")
		}
		panes = append(panes, livePane{fields[0], fields[1], fields[2], fields[3], fields[4]})
	}
	return panes
}

func waitForPane(t *testing.T, runner tmux.Runner, sessionID string, ok func(livePane) bool) livePane {
	t.Helper()
	deadline := time.Now().Add(sessionIntegrationWaitTimeout)
	for {
		panes := sessionPanes(t, runner, sessionID)
		if len(panes) == 1 && ok(panes[0]) {
			return panes[0]
		}
		if time.Now().After(deadline) {
			t.Fatalf("panes of %s = %+v", sessionID, panes)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// With base-index and pane-base-index 1 a session's only pane is 1.1, so a
// launch that targets =name:0.0 fails ("can't find window: 0"). Shell and
// agent sessions start through the pane ID new-session reports.
func TestIntegrationStartWithBaseIndexOne(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	t.Setenv("SHELL", "/bin/sh") // the shell session starts a login shell
	runner := baseIndexOneRunner(t)
	svc := fakeAgentService(t, runner, "exec sleep 600\n")

	for _, tt := range []struct {
		name  string
		opts  StartOpts
		role  string
		clock int64
	}{
		{name: "shell", opts: StartOpts{Shell: true}, role: tmux.RoleShell, clock: 1700000301},
		{name: "agent", opts: StartOpts{}, role: tmux.RoleAgent, clock: 1700000302},
	} {
		svc.Now = func() int64 { return tt.clock }
		tt.opts.Cwd = t.TempDir()
		result, err := svc.Start(t.Context(), tt.opts)
		if err != nil {
			t.Fatalf("Start %s session on a base-index 1 server: %v", tt.name, err)
		}
		pane := waitForPane(t, runner, result.SessionID, func(p livePane) bool { return p.role == tt.role })
		if pane.window != "1" || pane.pane != "1" || pane.dead != "0" {
			t.Fatalf("%s pane = %+v, want a live pane 1.1", tt.name, pane)
		}
	}
}

// An agent that exits leaves a dead pane (remain-on-exit). Continue finds it
// through the session's alive check, respawns the agent with its resume ID in
// the same pane, and records the exit status.
func TestIntegrationContinueRespawnsADeadAgentPane(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	runner := baseIndexOneRunner(t)
	// The first run exits 17; the respawn writes a marker before it stays up.
	marker := filepath.Join(t.TempDir(), "agent-started")
	respawned := marker + ".respawned"
	svc := fakeAgentService(t, runner, fmt.Sprintf(`marker=%q
respawned=%q
if [ -e "$marker" ]; then : > "$respawned"; exec sleep 600; fi
: > "$marker"
exit 17
`, marker, respawned))
	svc.Now = func() int64 { return 1700000303 }
	result, err := svc.Start(t.Context(), StartOpts{Cwd: t.TempDir(), ResumeIDs: map[string]string{"claude": "resume-17"}})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	dead := waitForPane(t, runner, result.SessionID, func(p livePane) bool { return p.dead == "1" })

	got, err := svc.Continue(t.Context(), result.SessionID)
	if err != nil {
		t.Fatalf("Continue: %v", err)
	}
	if !got.Reattach || !got.Respawned || got.AgentExit != "exit 17" {
		t.Fatalf("Continue = %+v, want a reattach that respawned an agent which exited 17", got)
	}
	waitForFile(t, respawned)
	alive := waitForPane(t, runner, result.SessionID, func(p livePane) bool { return p.dead == "0" })
	if alive.id != dead.id || alive.role != tmux.RoleAgent {
		t.Fatalf("respawned pane = %+v, want the agent pane %s alive", alive, dead.id)
	}
	m, err := svc.Store.Read(result.SessionID)
	if err != nil {
		t.Fatal(err)
	}
	if m.ExtraString("last_agent_exit") != "exit 17" || m.ExtraString("claude_session_id") != "resume-17" {
		t.Fatalf("manifest after respawn: last_agent_exit=%q claude_session_id=%q", m.ExtraString("last_agent_exit"), m.ExtraString("claude_session_id"))
	}
}

func waitForFile(t *testing.T, path string) {
	t.Helper()
	deadline := time.Now().Add(sessionIntegrationWaitTimeout)
	for {
		if _, err := os.Stat(path); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for private tmux pane to write %s", path)
		}
		time.Sleep(20 * time.Millisecond)
	}
}
