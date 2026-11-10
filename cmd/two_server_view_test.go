package cmd

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

type viewRunner func(context.Context, ...string) (string, error)

func (f viewRunner) Run(ctx context.Context, args ...string) (string, error) { return f(ctx, args...) }

func TestPruneAbortsOnUnavailableServer(t *testing.T) {
	for _, dryRun := range []bool{false, true} {
		t.Run(map[bool]string{true: "dry", false: "real"}[dryRun], func(t *testing.T) {
			store := state.OpenStore(t.TempDir())
			writeManifestFile(t, store.Root(), "qm-old", map[string]any{"session_id": "qm-old"}, 10*24*time.Hour)
			legacy := tmux.NewClient(viewRunner(func(context.Context, ...string) (string, error) {
				return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
			}))
			named := tmux.NewClient(viewRunner(func(context.Context, ...string) (string, error) { return "", context.DeadlineExceeded }))
			router := tmuxroute.New(store, map[string]*tmux.Client{"default": tmux.NewClient(allPassRunner()), "dev_previous": legacy, "questmaster": named}, func() string { return "dev_previous" }, nil)
			result, err := pruneManifestsWithLegacyRoot(t.Context(), store, legacy, 7, dryRun, "", router)
			if err == nil || result.Pruned != 0 || result.DroppedWatches != 0 {
				t.Fatalf("result=%+v err=%v", result, err)
			}
			if _, err := os.Stat(filepath.Join(store.Root(), "qm-old.json")); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestPruneProtectsLiveOnEitherServer(t *testing.T) {
	for _, dryRun := range []bool{false, true} {
		t.Run(map[bool]string{true: "dry", false: "real"}[dryRun], func(t *testing.T) {
			store := state.OpenStore(t.TempDir())
			if err := store.Create(state.Manifest{TmuxServer: "dev_previous", SessionID: "qm-live"}); err != nil {
				t.Fatal(err)
			}
			pr, err := state.ParsePullRequestRef("owner/repo#12")
			if err != nil {
				t.Fatal(err)
			}
			if _, err := state.WatchPullRequest(store.Root(), "qm-live", pr, time.Now()); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(store.Root(), "qm-live.json"), []byte("bad json"), 0o600); err != nil {
				t.Fatal(err)
			}
			past := time.Now().Add(-10 * 24 * time.Hour)
			if err := os.Chtimes(filepath.Join(store.Root(), "qm-live.json"), past, past); err != nil {
				t.Fatal(err)
			}
			legacy := tmux.NewClient(viewRunner(func(context.Context, ...string) (string, error) {
				return "", &tmux.ExitError{Code: 1, Stderr: "no server running"}
			}))
			named := tmux.NewClient(viewRunner(func(context.Context, ...string) (string, error) { return "qm-live", nil }))
			router := tmuxroute.New(store, map[string]*tmux.Client{"default": tmux.NewClient(allPassRunner()), "dev_previous": legacy, "questmaster": named}, func() string { return "dev_previous" }, nil)
			result, err := pruneManifestsWithLegacyRoot(t.Context(), store, legacy, 7, dryRun, "", router)
			if err != nil || result.Pruned != 0 || result.DroppedWatches != 0 {
				t.Fatalf("result=%+v err=%v", result, err)
			}
			if _, err := os.Stat(filepath.Join(store.Root(), "qm-live.json")); err != nil {
				t.Fatal(err)
			}
			prs, err := state.LoadPullRequests(store.Root())
			if err != nil || len(prs) != 1 || len(prs[0].Watchers) != 1 {
				t.Fatalf("watches=%+v err=%v", prs, err)
			}
		})
	}
}
