//go:build linux || darwin

package serve

import (
	"context"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

type snapshotRunner func(context.Context, ...string) (string, error)

func (f snapshotRunner) Run(ctx context.Context, args ...string) (string, error) {
	return f(ctx, args...)
}

func TestSnapshotListsEachServerOncePerRefresh(t *testing.T) {
	env := seedServeFixture(t)
	defaultCalls, namedCalls := 0, 0
	legacy := tmux.NewClient(snapshotRunner(func(context.Context, ...string) (string, error) { defaultCalls++; return "qm-demo", nil }))
	named := tmux.NewClient(snapshotRunner(func(context.Context, ...string) (string, error) {
		namedCalls++
		return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
	}))
	router := tmuxroute.New(env.store, map[string]*tmux.Client{"default": legacy, "questmaster": named}, func() string { return "default" }, nil)
	snap := NewSnapshotter(env.store, legacy, func() time.Time { return env.now }, router)
	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatal(err)
	}
	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatal(err)
	}
	if defaultCalls != 1 || namedCalls != 1 {
		t.Fatalf("calls = %d, %d", defaultCalls, namedCalls)
	}
	snap.Invalidate(Change{Topics: []string{topicTracker}, Lifecycle: true})
	if _, err := snap.TrackerForChange(Change{}); err != nil {
		t.Fatal(err)
	}
	if defaultCalls != 2 || namedCalls != 2 {
		t.Fatalf("after lifecycle = %d, %d", defaultCalls, namedCalls)
	}
}

func TestSnapshotRequiresRouter(t *testing.T) {
	env := seedServeFixture(t)
	client := tmux.NewClient(snapshotRunner(func(context.Context, ...string) (string, error) { t.Fatal("tmux was called"); return "", nil }))
	if _, err := NewSnapshotter(env.store, client, time.Now, nil).TrackerForChange(Change{}); err == nil {
		t.Fatal("nil router produced a tracker snapshot")
	}
}
