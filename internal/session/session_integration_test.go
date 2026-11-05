//go:build linux || darwin

package session

import (
	"testing"

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
