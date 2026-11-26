//go:build linux || darwin

package state

import (
	"os"
	"sync"
	"testing"
)

func TestAgentAvailabilityMissingFileEnablesUnconfiguredAgents(t *testing.T) {
	t.Parallel()

	store := NewAgentAvailabilityStore(t.TempDir())
	settings, err := store.Load()
	if err != nil {
		t.Fatalf("Load missing preference: %v", err)
	}
	if len(settings) != 0 {
		t.Fatalf("settings = %v, want no saved entries", settings)
	}
	enabled, err := store.Enabled("claude")
	if err != nil || !enabled {
		t.Fatalf("Enabled(claude) = %v, %v; want enabled", enabled, err)
	}
}

func TestAgentAvailabilitySetReenablesAndPreservesOtherAgents(t *testing.T) {
	t.Parallel()

	store := NewAgentAvailabilityStore(t.TempDir())
	if err := store.Set("claude", false); err != nil {
		t.Fatalf("disable claude: %v", err)
	}
	if err := store.Set("codex", false); err != nil {
		t.Fatalf("disable codex: %v", err)
	}
	if err := store.Set("claude", true); err != nil {
		t.Fatalf("re-enable claude: %v", err)
	}

	claude, err := store.Enabled("claude")
	if err != nil || !claude {
		t.Fatalf("claude enabled = %v, %v; want true", claude, err)
	}
	codex, err := store.Enabled("codex")
	if err != nil || codex {
		t.Fatalf("codex enabled = %v, %v; want false", codex, err)
	}
	opencode, err := store.Enabled("opencode")
	if err != nil || !opencode {
		t.Fatalf("opencode enabled = %v, %v; want default true", opencode, err)
	}
}

func TestAgentAvailabilityConcurrentUpdatesPreserveEachAgent(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	names := []string{"claude", "codex", "opencode", "pi"}
	var wg sync.WaitGroup
	errs := make(chan error, len(names))
	for _, name := range names {
		name := name
		wg.Add(1)
		go func() {
			defer wg.Done()
			errs <- NewAgentAvailabilityStore(root).Set(name, false)
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatalf("concurrent Set: %v", err)
		}
	}

	settings, err := NewAgentAvailabilityStore(root).Load()
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	for _, name := range names {
		if enabled, ok := settings[name]; !ok || enabled {
			t.Errorf("setting for %s = %v (present %v), want false", name, enabled, ok)
		}
	}
}

func TestAgentAvailabilityRejectsCorruptPreferenceWithoutReplacingIt(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	path := NewAgentAvailabilityStore(root).path
	want := []byte("not json")
	if err := os.WriteFile(path, want, 0o600); err != nil {
		t.Fatalf("write corrupt preference: %v", err)
	}
	if err := NewAgentAvailabilityStore(root).Set("claude", true); err == nil {
		t.Fatal("Set on corrupt preference succeeded")
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read preference: %v", err)
	}
	if string(got) != string(want) {
		t.Fatalf("preference after failed Set = %q, want original %q", got, want)
	}
}
