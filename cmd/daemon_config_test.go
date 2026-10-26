//go:build linux || darwin

package cmd

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func TestDaemonConfigRegistersSessionClassBackfillJob(t *testing.T) {
	t.Parallel()

	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	config, err := newDaemonConfig(store, tmux.NewClient(&pruneRunner{sessions: map[string]bool{}}))
	if err != nil {
		t.Fatalf("daemon config: %v", err)
	}
	if len(config.Jobs) != 1 || config.Jobs[0].Name() != "session-class-backfill" {
		t.Fatalf("daemon jobs = %#v, want registered session-class-backfill job", config.Jobs)
	}
}

func TestDaemonClassBackfillUsesAbsoluteStateRootAfterChdir(t *testing.T) {
	originalDir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := os.Chdir(originalDir); err != nil {
			t.Errorf("restore working directory: %v", err)
		}
	}()

	absoluteRoot := filepath.Join(t.TempDir(), "state")
	store, err := state.NewStore(absoluteRoot)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(state.Manifest{
		SessionID: "qm-relative-root",
		Agents:    []state.AgentManifest{{Name: "codex", Role: "agent"}},
	}); err != nil {
		t.Fatalf("create master: %v", err)
	}
	relativeRoot, err := filepath.Rel(originalDir, absoluteRoot)
	if err != nil {
		t.Fatalf("relative root: %v", err)
	}
	config, err := newDaemonConfig(state.OpenStore(relativeRoot), tmux.NewClient(&pruneRunner{sessions: map[string]bool{"qm-relative-root": true}}))
	if err != nil {
		t.Fatalf("daemon config: %v", err)
	}
	if config.Root != absoluteRoot {
		t.Fatalf("daemon root = %q, want %q", config.Root, absoluteRoot)
	}
	if err := os.Chdir(t.TempDir()); err != nil {
		t.Fatalf("change working directory: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- config.Jobs[0].Run(ctx) }()
	deadline := time.NewTimer(3 * time.Second)
	ticker := time.NewTicker(time.Millisecond)
	defer deadline.Stop()
	defer ticker.Stop()
	for {
		manifest, err := store.Read("qm-relative-root")
		if err != nil {
			cancel()
			t.Fatalf("read master: %v", err)
		}
		if manifest.DisplayClass() != "" {
			break
		}
		select {
		case err := <-done:
			cancel()
			t.Fatalf("backfill returned before cancellation: %v", err)
		case <-deadline.C:
			cancel()
			t.Fatal("backfill did not persist class in the original state root")
		case <-ticker.C:
		}
	}
	cancel()
	if err := <-done; err != nil {
		t.Fatalf("backfill after cancellation: %v", err)
	}
}
