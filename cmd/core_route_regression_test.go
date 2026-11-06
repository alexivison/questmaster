package cmd

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestProductionRouterPreservesCLISendTimeout(t *testing.T) {
	root := t.TempDir()
	client := newCLITmuxClient(root)
	router, err := tmuxroute.NewProduction(state.OpenStore(root), client)
	if err != nil {
		t.Fatal(err)
	}
	handle, err := router.Creation()
	if err != nil {
		t.Fatal(err)
	}
	if got := handle.Client().SendTimeout; got != cliSendTimeout {
		t.Fatalf("actual CLI route SendTimeout=%s, want %s", got, cliSendTimeout)
	}
}

func TestIntegrationPruneProtectsCorruptManifestOnPreviousDevLabel(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	t.Setenv("HOME", t.TempDir())
	root := t.TempDir()
	t.Setenv(state.StateRootEnv, root)
	store := state.OpenStore(root)
	previous := tmuxtest.NewRunner(t)
	id := "qm-dev-protected"
	if _, err := previous.Run(t.Context(), "new-session", "-d", "-s", id, "sleep 60"); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, id+".json")
	if err := os.WriteFile(path, []byte("{"), 0600); err != nil {
		t.Fatal(err)
	}
	past := time.Now().Add(-10 * 24 * time.Hour)
	if err := os.Chtimes(path, past, past); err != nil {
		t.Fatal(err)
	}
	runtime := state.NewRuntimeDir(root, id)
	if err := state.EnsureRuntimeDir(runtime); err != nil {
		t.Fatal(err)
	}
	// A corrupt manifest cannot reveal its former dev label to this router.
	router := tmuxroute.New(store, map[string]*tmux.Client{
		"default":     tmux.NewClient(tmuxtest.NewRunner(t)),
		"questmaster": tmux.NewClient(tmuxtest.NewRunner(t)),
	}, func() string { return "questmaster" }, nil)
	result, err := pruneManifestsWithLegacyRoot(context.Background(), store, nil, 7, false, "", router)
	if err == nil || result.Pruned != 0 {
		t.Fatalf("prune with incomplete view = %+v, %v", result, err)
	}
	alive, probeErr := tmux.NewClient(previous).HasSession(t.Context(), id)
	if probeErr != nil || !alive {
		t.Fatalf("private dev session was lost: %v, %v", alive, probeErr)
	}
	_, manifestErr := os.Stat(path)
	_, runtimeErr := os.Stat(runtime)
	t.Logf("prune=%+v, err=%v, private dev session live=%v, manifest gone=%v, runtime gone=%v", result, err, alive, os.IsNotExist(manifestErr), os.IsNotExist(runtimeErr))
	if os.IsNotExist(manifestErr) || os.IsNotExist(runtimeErr) {
		t.Fatal("prune deleted live dev session metadata/runtime after failing to discover its server")
	}
}
