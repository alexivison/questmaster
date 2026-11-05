//go:build linux || darwin

package session

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
)

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
	if err := store.Create(state.Manifest{SessionID: base, Cwd: t.TempDir()}); err != nil {
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
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	id := uniqueRuntimeSessionID(t, "qm-race")
	if err := store.Create(state.Manifest{SessionID: id, Cwd: t.TempDir()}); err != nil {
		t.Fatal(err)
	}
	runner := newCheckBarrier(tmuxtest.NewRunner(t), 2, time.Second)
	client := tmux.NewClient(runner)
	svc := &Service{Store: store, Client: client}

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
	t.Setenv("SHELL", "/bin/sh") // shell sessions start a login shell
	store, err := state.NewStore(filepath.Join(shortTempDir(t), `a b'c"d$e#Sf\g`))
	if err != nil {
		t.Fatal(err)
	}
	svc := NewService(store, tmux.NewClient(tmuxtest.NewRunner(t)), "")
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
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Lstat(closed.RuntimeDir); errors.Is(err, os.ErrNotExist) {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("session-closed hook did not remove %s", closed.RuntimeDir)
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, err := os.Stat(filepath.Join(live.RuntimeDir, "cleanup.sh")); err != nil {
		t.Fatalf("live session's runtime dir touched: %v", err)
	}
}
