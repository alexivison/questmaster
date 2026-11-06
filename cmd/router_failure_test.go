package cmd

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func TestPruneRejectsRouterConstructionErrorWithoutChanges(t *testing.T) {
	store := state.OpenStore(t.TempDir())
	writeManifestFile(t, store.Root(), "qm-named", map[string]any{"session_id": "qm-named", "tmux_server": "questmaster"}, 10*24*time.Hour)
	pr, err := state.ParsePullRequestRef("owner/repo#12")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := state.WatchPullRequest(store.Root(), "qm-named", pr, time.Now()); err != nil {
		t.Fatal(err)
	}
	runtimeDir := filepath.Join(store.Root(), "runtime", "qm-named")
	if err := os.MkdirAll(runtimeDir, 0o700); err != nil {
		t.Fatal(err)
	}
	client := tmux.NewClient(viewRunner(func(context.Context, ...string) (string, error) { t.Fatal("tmux was called"); return "", nil }))
	routeErr := errors.New("invalid QUESTMASTER_TMUX_LABEL")
	cmd := newPruneCmd(store, client, nil, routeErr)
	cmd.SetOut(&bytes.Buffer{})
	cmd.SetArgs([]string{"--days", "7"})
	if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), routeErr.Error()) {
		t.Fatalf("prune error = %v", err)
	}
	for _, path := range []string{filepath.Join(store.Root(), "qm-named.json"), runtimeDir} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("%s changed: %v", path, err)
		}
	}
	prs, err := state.LoadPullRequests(store.Root())
	if err != nil || len(prs) != 1 || len(prs[0].Watchers) != 1 {
		t.Fatalf("watches changed: %+v, %v", prs, err)
	}
}

func TestListAndSessionsRejectRouterConstructionError(t *testing.T) {
	store := state.OpenStore(t.TempDir())
	client := tmux.NewClient(viewRunner(func(context.Context, ...string) (string, error) { t.Fatal("tmux was called"); return "", nil }))
	routeErr := errors.New("invalid QUESTMASTER_TMUX_LABEL")
	for _, cmd := range []struct {
		name string
		run  func() error
	}{
		{"list", func() error { c := newListCmd(store, client, nil, routeErr); c.SetArgs(nil); return c.Execute() }},
		{"sessions", func() error { c := newSessionsCmd(store, client, nil, routeErr); c.SetArgs(nil); return c.Execute() }},
	} {
		if err := cmd.run(); err == nil || !strings.Contains(err.Error(), routeErr.Error()) {
			t.Fatalf("%s error = %v", cmd.name, err)
		}
	}
}

func TestRootReadersRejectInvalidNamedLabel(t *testing.T) {
	t.Setenv("QUESTMASTER_TMUX_LABEL", "bad label")
	store := state.OpenStore(t.TempDir())
	client := tmux.NewClient(viewRunner(func(context.Context, ...string) (string, error) { t.Fatal("tmux was called"); return "", nil }))
	for _, args := range [][]string{{"prune", "--days", "7"}, {"list"}, {"sessions"}, {"status", "qm-named"}} {
		cmd := NewRootCmd(WithDeps(store, client))
		cmd.SetOut(&bytes.Buffer{})
		cmd.SetErr(&bytes.Buffer{})
		cmd.SetArgs(args)
		if err := cmd.Execute(); err == nil || !strings.Contains(err.Error(), "QUESTMASTER_TMUX_LABEL") {
			t.Fatalf("%v error = %v", args, err)
		}
	}
}
