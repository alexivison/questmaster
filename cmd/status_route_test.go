package cmd

import (
	"context"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestStatusRoutesToRecordedServer(t *testing.T) {
	store := setupStore(t)
	createManifest(t, store, "qm-example", "example", "/tmp", "master")
	if err := store.Update("qm-example", func(m *state.Manifest) { m.TmuxServer = "questmaster" }); err != nil {
		t.Fatal(err)
	}
	legacyCalls, namedCalls := 0, 0
	run := func(calls *int, live bool) *mockRunner {
		return &mockRunner{fn: func(_ context.Context, args ...string) (string, error) {
			if args[0] == "has-session" {
				(*calls)++
				if !live {
					return "", &tmux.ExitError{Code: 1}
				}
			}
			return "", nil
		}}
	}
	legacy, named := tmux.NewClient(run(&legacyCalls, false)), tmux.NewClient(run(&namedCalls, true))
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": legacy, "questmaster": named}, func() string { return "default" }, nil)
	if _, err := collectStatusRouted(t.Context(), store, legacy, router, "qm-example"); err != nil {
		t.Fatal(err)
	}
	if legacyCalls != 0 || namedCalls != 1 {
		t.Fatalf("liveness calls: legacy=%d named=%d", legacyCalls, namedCalls)
	}
}
