//go:build linux || darwin

package cmd

import (
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func TestDaemonConfigRegistersSessionClassBackfillJob(t *testing.T) {
	t.Parallel()

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	config := newDaemonConfig(store)
	if len(config.Jobs) != 1 || config.Jobs[0].Name() != "session-class-backfill" {
		t.Fatalf("daemon jobs = %#v, want registered session-class-backfill job", config.Jobs)
	}
}
