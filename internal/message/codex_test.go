package message

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/alexivison/questmaster/internal/codexnative"
	"github.com/alexivison/questmaster/internal/state"
)

func TestManagedCodexNeverFallsBackToTmuxWhenOwnerUnavailable(t *testing.T) {
	store, svc, legacy, named := routeFixture(t)
	const id = "qm-native-worker"
	routeManifest(t, store, id, "worker", "questmaster", "")
	root, err := os.MkdirTemp("/tmp", "qm-native-test-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(root) })
	dir := filepath.Join(root, id)
	if err := state.EnsureRuntimeDir(dir); err != nil {
		t.Fatal(err)
	}
	if err := state.WriteRuntimeFile(dir, codexnative.MarkerName, []byte("1\n")); err != nil {
		t.Fatal(err)
	}
	if err := store.Update(id, func(m *state.Manifest) { m.RuntimeDir = dir; m.Agents[0].ResumeID = "example-thread" }); err != nil {
		t.Fatal(err)
	}
	if delivery, err := svc.Relay(t.Context(), id, "change course"); err == nil || delivery != "" {
		t.Fatalf("delivery=%q error=%v", delivery, err)
	}
	if *legacy != 0 || *named != 0 {
		t.Fatalf("tmux fallback occurred: %d/%d", *legacy, *named)
	}
}
