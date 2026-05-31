package picker

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
	for _, d := range []string{d1, d2} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
	}

	// qm-new and qm-mid share d1 (must dedupe to one entry); qm-old uses d2;
	// the empty and missing cwds must be skipped.
	writeManifest(t, root, state.Manifest{SessionID: "qm-new", Cwd: d1})
	writeManifest(t, root, state.Manifest{SessionID: "qm-mid", Cwd: d1})
	writeManifest(t, root, state.Manifest{SessionID: "qm-old", Cwd: d2})
	writeManifest(t, root, state.Manifest{SessionID: "qm-empty", Cwd: ""})
	writeManifest(t, root, state.Manifest{SessionID: "qm-missing", Cwd: filepath.Join(root, "gone")})

	now := time.Now()
	setMtime(t, root, "qm-new", now)
	setMtime(t, root, "qm-mid", now.Add(-time.Hour))
	setMtime(t, root, "qm-old", now.Add(-2*time.Hour))

	store := state.OpenStore(root)

	got := RecentDirs(store, 20)
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
	for _, d := range []string{d1, d2} {
		if err := os.MkdirAll(d, 0o755); err != nil {
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

func setMtime(t *testing.T, root, id string, ts time.Time) {
	t.Helper()
	path := filepath.Join(root, id+".json")
	if err := os.Chtimes(path, ts, ts); err != nil {
		t.Fatalf("chtimes %s: %v", id, err)
	}
}
