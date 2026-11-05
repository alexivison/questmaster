//go:build linux || darwin

package session

import (
	"context"
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
