package prstatus

import (
	"context"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestUnlabelledManifestDoesNotBreakAggregates(t *testing.T) {
	t.Parallel()
	store := state.OpenStore(t.TempDir())
	for _, m := range []state.Manifest{{SessionID: "qm-labelled", TmuxServer: "questmaster"}, {SessionID: "qm-unlabelled"}} {
		if err := store.Create(m); err != nil {
			t.Fatal(err)
		}
	}
	client := tmux.NewClient(jobTmux(func(context.Context, ...string) (string, error) { return "qm-labelled\nqm-unlabelled", nil }))
	router := tmuxroute.New(store, map[string]*tmux.Client{"questmaster": client}, func() string { return "questmaster" }, nil)
	got, err := NewJob(store.Root(), client, nil, router).liveIDs(t.Context(), []string{"qm-labelled", "qm-unlabelled"})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || !got["qm-labelled"] || got["qm-unlabelled"] {
		t.Fatalf("live=%v", got)
	}
}
