package cmd

import (
	"path/filepath"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/fsnotify/fsnotify"
)

func watchManifestDirectory(t *testing.T, root string) *fsnotify.Watcher {
	t.Helper()
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		t.Fatalf("create manifest watcher: %v", err)
	}
	if err := watcher.Add(root); err != nil {
		watcher.Close()
		t.Fatalf("watch state root: %v", err)
	}
	t.Cleanup(func() {
		if err := watcher.Close(); err != nil {
			t.Errorf("close manifest watcher: %v", err)
		}
	})
	return watcher
}

func waitForManifestDisplayClass(t *testing.T, watcher *fsnotify.Watcher, store *state.Store, sessionID string, done <-chan error) state.Manifest {
	t.Helper()
	manifestPath := filepath.Clean(filepath.Join(store.Root(), sessionID+".json"))
	for {
		select {
		case event, ok := <-watcher.Events:
			if !ok {
				t.Fatal("manifest watcher closed before the class write")
			}
			if filepath.Clean(event.Name) != manifestPath {
				continue
			}
			manifest, err := store.Read(sessionID)
			if err != nil {
				t.Fatalf("read backfilled manifest: %v", err)
			}
			if manifest.DisplayClass() != "" {
				return manifest
			}
		case err, ok := <-watcher.Errors:
			if !ok {
				t.Fatal("manifest watcher errors channel closed before the class write")
			}
			t.Fatalf("manifest watcher: %v", err)
		case err := <-done:
			t.Fatalf("backfill returned before writing the class: %v", err)
		}
	}
}
