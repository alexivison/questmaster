//go:build linux || darwin

package session

import (
	"context"
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
	live, classes, err := liveMasterClasses(t.Context(), store, legacy, router)
	if err != nil {
		t.Fatal(err)
	}
	if len(live) != 2 || len(classes) != 2 {
		t.Fatalf("live=%v classes=%v", live, classes)
	}
}
