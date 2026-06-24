package dirsuggest

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func TestRecentDirs(t *testing.T) {
	root := t.TempDir()
	d1 := filepath.Join(root, "alpha")
	d2 := filepath.Join(root, "beta")
	for _, dir := range []string{d1, d2} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
	}

	writeManifest(t, root, state.Manifest{SessionID: "qm-new", Cwd: d1})
	writeManifest(t, root, state.Manifest{SessionID: "qm-mid", Cwd: d1})
	writeManifest(t, root, state.Manifest{SessionID: "qm-old", Cwd: d2})
	writeManifest(t, root, state.Manifest{SessionID: "qm-empty", Cwd: ""})
	writeManifest(t, root, state.Manifest{SessionID: "qm-missing", Cwd: filepath.Join(root, "gone")})

	now := time.Now()
	setMtime(t, root, "qm-new", now)
	setMtime(t, root, "qm-mid", now.Add(-time.Hour))
	setMtime(t, root, "qm-old", now.Add(-2*time.Hour))

	got := RecentDirs(state.OpenStore(root), 20)
	want := []string{d1, d2}
	if len(got) != len(want) {
		t.Fatalf("RecentDirs = %v, want %v", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("RecentDirs[%d] = %q, want %q (full %v)", i, got[i], want[i], got)
		}
	}
}

func TestRecentDirsRespectsLimit(t *testing.T) {
	root := t.TempDir()
	d1 := filepath.Join(root, "a")
	d2 := filepath.Join(root, "b")
	for _, dir := range []string{d1, d2} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
	}
	writeManifest(t, root, state.Manifest{SessionID: "qm-1", Cwd: d1})
	writeManifest(t, root, state.Manifest{SessionID: "qm-2", Cwd: d2})
	setMtime(t, root, "qm-1", time.Now())
	setMtime(t, root, "qm-2", time.Now().Add(-time.Hour))

	store := state.OpenStore(root)
	if got := RecentDirs(store, 1); len(got) != 1 || got[0] != d1 {
		t.Fatalf("RecentDirs limit=1 = %v, want [%q]", got, d1)
	}
	if got := RecentDirs(store, 0); got != nil {
		t.Fatalf("RecentDirs limit=0 = %v, want nil", got)
	}
}

func writeManifest(t *testing.T, root string, m state.Manifest) {
	t.Helper()
	store, err := state.NewStore(root)
	if err != nil {
		t.Fatalf("new store: %v", err)
	}
	if err := store.Create(m); err != nil {
		t.Fatalf("write manifest %s: %v", m.SessionID, err)
	}
}

func setMtime(t *testing.T, root, id string, ts time.Time) {
	t.Helper()
	path := filepath.Join(root, id+".json")
	if err := os.Chtimes(path, ts, ts); err != nil {
		t.Fatalf("chtimes %s: %v", id, err)
	}
}
