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

func TestIntegrationCleanupProtectsDefaultOnlySession(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	root := t.TempDir()
	t.Setenv("QUESTMASTER_STATE_ROOT", root)
	t.Setenv("HOME", t.TempDir())
	store := state.OpenStore(root)
	first, second := tmuxtest.NewRunner(t), tmuxtest.NewRunner(t)
	id := "qm-default-live"
	if _, err := first.Run(t.Context(), "new-session", "-d", "-s", id, "sleep 60"); err != nil {
		t.Fatal(err)
	}
	if err := store.Create(state.Manifest{SessionID: id, RuntimeDir: state.NewRuntimeDir(root, id)}); err != nil {
		t.Fatal(err)
	}
	runtime := state.NewRuntimeDir(root, id)
	if err := os.MkdirAll(runtime, 0700); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(root, id+".json")
	old := time.Now().Add(-10 * 24 * time.Hour)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	client := tmux.NewClient(second)
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": tmux.NewClient(first), "questmaster": client}, func() string { return "questmaster" }, nil)
	got, err := pruneManifestsWithLegacyRoot(context.Background(), store, client, 7, false, "", router)
	if err != nil {
		t.Fatal(err)
	}
	if got.Pruned != 0 {
		t.Errorf("pruned live default metadata: %+v", got)
	}
	if _, err := os.Stat(path); err != nil {
		t.Errorf("manifest lost: %v", err)
	}
	if _, err := os.Stat(runtime); err != nil {
		t.Errorf("runtime lost: %v", err)
	}
}
