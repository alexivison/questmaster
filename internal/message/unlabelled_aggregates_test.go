package message

import (
	"context"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestUnlabelledManifestDoesNotBreakAggregates(t *testing.T) {
	t.Parallel()
	store := setupStore(t)
	for _, m := range []state.Manifest{{SessionID: "qm-labelled", TmuxServer: "questmaster", Workers: []string{"qm-ghost", "qm-unlabelled"}}, {SessionID: "qm-unlabelled", Title: "old worker"}} {
		if err := store.Create(m); err != nil {
			t.Fatal(err)
		}
	}
	client := tmux.NewClient(&mockRunner{fn: func(_ context.Context, args ...string) (string, error) { return "", &tmux.ExitError{Code: 1} }})
	router := tmuxroute.New(store, map[string]*tmux.Client{"questmaster": client}, func() string { return "questmaster" }, nil)
	got, err := NewServiceWithRouter(store, router).Workers(t.Context(), "qm-labelled")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].SessionID != "qm-unlabelled" || got[0].Status != "stopped" || got[0].Title != "old worker" {
		t.Fatalf("workers=%+v", got)
	}
	m, err := store.Read("qm-labelled")
	if err != nil {
		t.Fatal(err)
	}
	if len(m.Workers) != 1 || m.Workers[0] != "qm-unlabelled" {
		t.Fatalf("workers retained=%v", m.Workers)
	}
}
