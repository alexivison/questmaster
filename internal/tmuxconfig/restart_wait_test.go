package tmuxconfig_test

import (
	"context"
	"testing"

	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxconfig"
)

// exitingRunner kills the server on if-shell, then reports it alive for
// aliveFor more list-sessions calls before it is gone (or forever when < 0).
type exitingRunner struct {
	aliveFor int
	listings int
}

func (r *exitingRunner) Run(_ context.Context, args ...string) (string, error) {
	switch args[0] {
	case "if-shell":
		return "", nil
	case "list-sessions":
		r.listings++
		if r.aliveFor < 0 || r.listings <= r.aliveFor {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1, Stderr: "no server running on private socket"}
	}
	return "", nil
}

func TestRestartIfEmptyWaitsForTheServerToExit(t *testing.T) {
	t.Parallel()
	r := &exitingRunner{aliveFor: 2}
	result, err := tmuxconfig.RestartIfEmpty(t.Context(), tmux.NewClient(r))
	if err != nil || !result.Restarted {
		t.Fatalf("restart: %+v, %v", result, err)
	}
	if r.listings != 3 {
		t.Fatalf("list-sessions calls = %d, want 3 (twice still running, then gone)", r.listings)
	}
}

func TestRestartIfEmptyErrorsWhenTheServerDoesNotExit(t *testing.T) {
	t.Parallel()
	r := &exitingRunner{aliveFor: -1}
	result, err := tmuxconfig.RestartIfEmpty(t.Context(), tmux.NewClient(r))
	if err == nil || result.Restarted {
		t.Fatalf("restart of a server that never exits: %+v, %v", result, err)
	}
}
