//go:build linux || darwin

package session

import (
	"context"
	"fmt"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

type backfillViewRunner func(context.Context, ...string) (string, error)

func (f backfillViewRunner) Run(ctx context.Context, args ...string) (string, error) {
	return f(ctx, args...)
}

func TestClassBackfillSeesBothServers(t *testing.T) {
	store := state.OpenStore(t.TempDir())
	createClassBackfillMaster(t, store, "qm-one", "paladin")
	createClassBackfillMaster(t, store, "qm-two", "wizard")
	if err := store.Update("qm-two", func(m *state.Manifest) { m.TmuxServer = "questmaster" }); err != nil {
		t.Fatal(err)
	}
	legacy := tmux.NewClient(backfillViewRunner(func(context.Context, ...string) (string, error) { return "qm-one", nil }))
	named := tmux.NewClient(backfillViewRunner(func(context.Context, ...string) (string, error) { return "qm-two", nil }))
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": legacy, "questmaster": named}, func() string { return "default" }, nil)
	live, classes, err := routedLiveMasterClasses(t.Context(), store, router)
	if err != nil {
		t.Fatal(err)
	}
	if len(live) != 2 || len(classes) != 2 {
		t.Fatalf("live=%v classes=%v", live, classes)
	}
}

func TestClassBackfillBalancesFromAvailableServer(t *testing.T) {
	store := state.OpenStore(t.TempDir())
	createClassBackfillMaster(t, store, "qm-visible", "wizard")
	visible := tmux.NewClient(backfillViewRunner(func(context.Context, ...string) (string, error) { return "qm-visible", nil }))
	unavailable := tmux.NewClient(backfillViewRunner(func(context.Context, ...string) (string, error) { return "", fmt.Errorf("server unavailable") }))
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": unavailable, "questmaster": visible}, func() string { return "questmaster" }, nil)
	if err := store.Update("qm-visible", func(m *state.Manifest) { m.TmuxServer = "questmaster" }); err != nil {
		t.Fatal(err)
	}
	live, classes, err := visibleLiveMasterClasses(t.Context(), store, router)
	if err != nil || len(live) != 1 || len(classes) != 1 || classes[0] != "wizard" {
		t.Fatalf("live=%v classes=%v err=%v", live, classes, err)
	}
}

func TestClassBackfillRequiresRouter(t *testing.T) {
	store := state.OpenStore(t.TempDir())
	createClassBackfillMaster(t, store, "qm-named", "")
	client := tmux.NewClient(backfillViewRunner(func(context.Context, ...string) (string, error) { t.Fatal("tmux was called"); return "", nil }))
	if err := NewClassBackfillJob(store, client, nil).runPass(t.Context()); err == nil {
		t.Fatal("nil router backfilled from one server")
	}
}
