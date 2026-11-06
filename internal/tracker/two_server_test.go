package tracker

import (
	"context"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

type inventoryRunner func(context.Context, ...string) (string, error)

func (f inventoryRunner) Run(ctx context.Context, args ...string) (string, error) {
	return f(ctx, args...)
}

func TestTrackerJoinsByServerAndID(t *testing.T) {
	store := state.OpenStore(t.TempDir())
	if err := store.Create(state.Manifest{SessionID: "qm-one", TmuxServer: "questmaster"}); err != nil {
		t.Fatal(err)
	}
	legacy := tmux.NewClient(inventoryRunner(func(context.Context, ...string) (string, error) { return "qm-one", nil }))
	named := tmux.NewClient(inventoryRunner(func(context.Context, ...string) (string, error) {
		return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
	}))
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": legacy, "questmaster": named}, func() string { return "default" }, nil)
	snap, err := NewLiveSessionFetcher(legacy, store, state.NewProjectResolver(), router)(SessionInfo{})
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.Sessions) != 1 || snap.Sessions[0].Status == "active" {
		t.Fatalf("rows = %+v", snap.Sessions)
	}
}

func TestTrackerUnavailableServerKeepsRows(t *testing.T) {
	store := state.OpenStore(t.TempDir())
	if err := store.Create(state.Manifest{SessionID: "qm-one", TmuxServer: "questmaster"}); err != nil {
		t.Fatal(err)
	}
	broken := false
	named := tmux.NewClient(inventoryRunner(func(context.Context, ...string) (string, error) {
		if broken {
			return "", context.DeadlineExceeded
		}
		return "qm-one", nil
	}))
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": tmux.NewClient(inventoryRunner(func(context.Context, ...string) (string, error) {
		return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
	})), "questmaster": named}, func() string { return "default" }, nil)
	fetch := NewLiveSessionFetcher(nil, store, state.NewProjectResolver(), router)
	first, err := fetch(SessionInfo{})
	if err != nil || first.Sessions[0].Status != "active" {
		t.Fatalf("first = %+v, %v", first, err)
	}
	broken = true
	router.Invalidate()
	second, err := fetch(SessionInfo{})
	if err != nil || second.Sessions[0].Status != "active" {
		t.Fatalf("second = %+v, %v", second, err)
	}
}

func TestTrackerRequiresRouter(t *testing.T) {
	store := state.OpenStore(t.TempDir())
	if err := store.Create(state.Manifest{SessionID: "qm-named", TmuxServer: "questmaster"}); err != nil {
		t.Fatal(err)
	}
	client := tmux.NewClient(inventoryRunner(func(context.Context, ...string) (string, error) { t.Fatal("tmux was called"); return "", nil }))
	if _, err := NewLiveSessionFetcher(client, store, state.NewProjectResolver(), nil)(SessionInfo{}); err == nil {
		t.Fatal("nil router marked a named session stopped")
	}
}
