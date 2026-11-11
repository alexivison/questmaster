//go:build linux || darwin

package cmd

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmux/tmuxtest"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

func TestIntegrationMixedInventoryAndPrune(t *testing.T) {
	tmuxtest.RequireIntegration(t)
	root := t.TempDir()
	t.Setenv(state.StateRootEnv, root)
	t.Setenv("HOME", t.TempDir())
	store := state.OpenStore(root)
	legacy := tmuxtest.NewRunner(t)
	named := tmuxtest.NewRunner(t)
	for _, item := range []struct {
		runner *tmuxtest.Runner
		id     string
	}{{legacy, "qm-old-live"}, {named, "qm-new-live"}} {
		if _, err := item.runner.Run(t.Context(), "new-session", "-d", "-s", item.id, "-c", root, "sleep 60"); err != nil {
			t.Fatal(err)
		}
	}
	for _, item := range []struct{ id, label string }{{"qm-old-live", "dev_previous"}, {"qm-new-live", "questmaster"}} {
		if err := store.Create(state.Manifest{SessionID: item.id, TmuxServer: state.TmuxServer(item.label)}); err != nil {
			t.Fatal(err)
		}
	}
	writeManifestFile(t, root, "qm-stale", map[string]any{"session_id": "qm-stale", "tmux_server": "dev_previous"}, 10*24*time.Hour)
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": tmux.NewClient(allPassRunner()), "dev_previous": tmux.NewClient(legacy), "questmaster": tmux.NewClient(named)}, func() string { return "dev_previous" }, nil)
	inv := router.Inventory(t.Context())
	if len(inv.Rows) != 2 {
		t.Fatalf("inventory = %+v", inv)
	}
	listed, err := collectList(t.Context(), store, tmux.NewClient(legacy), router)
	if err != nil || len(listed.active) != 2 || len(listed.stale) != 1 {
		t.Fatalf("list = %+v, %v", listed, err)
	}
	for _, dryRun := range []bool{true, false} {
		result, err := pruneManifestsWithLegacyRoot(t.Context(), store, tmux.NewClient(legacy), 7, dryRun, "", router)
		if err != nil || result.Pruned != 1 {
			t.Fatalf("prune dry=%v: %+v, %v", dryRun, result, err)
		}
		for _, id := range []string{"qm-old-live", "qm-new-live"} {
			if _, err := os.Stat(filepath.Join(root, id+".json")); err != nil {
				t.Fatal(err)
			}
		}
	}
	if _, err := os.Stat(filepath.Join(root, "qm-stale.json")); !os.IsNotExist(err) {
		t.Fatalf("stale manifest remains: %v", err)
	}
}
