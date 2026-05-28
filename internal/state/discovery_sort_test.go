//go:build linux || darwin

package state

import (
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

func TestSortByMtime_PreservesInputOrderWithinEqualMtimeGroups(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	manifests := []Manifest{
		{SessionID: "qm-old"},
		{SessionID: "qm-tie-a"},
		{SessionID: "qm-tie-b"},
		{SessionID: "qm-new"},
	}

	setManifestMtime(t, root, "qm-old", time.Unix(10, 0))
	setManifestMtime(t, root, "qm-tie-a", time.Unix(20, 0))
	setManifestMtime(t, root, "qm-tie-b", time.Unix(20, 0))
	setManifestMtime(t, root, "qm-new", time.Unix(30, 0))

	SortByMtime(manifests, root)

	got := manifestIDs(manifests)
	want := []string{"qm-new", "qm-tie-a", "qm-tie-b", "qm-old"}
	if !slices.Equal(got, want) {
		t.Fatalf("sorted ids: got %v, want %v", got, want)
	}
}

func TestSortByMtime_PreservesInputOrderWhenAllMtimesMatch(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	manifests := []Manifest{
		{SessionID: "qm-c"},
		{SessionID: "qm-a"},
		{SessionID: "qm-b"},
	}

	mtime := time.Unix(42, 0)
	for _, manifest := range manifests {
		setManifestMtime(t, root, manifest.SessionID, mtime)
	}

	SortByMtime(manifests, root)

	got := manifestIDs(manifests)
	want := []string{"qm-c", "qm-a", "qm-b"}
	if !slices.Equal(got, want) {
		t.Fatalf("sorted ids: got %v, want %v", got, want)
	}
}

func setManifestMtime(t *testing.T, root, sessionID string, mtime time.Time) {
	t.Helper()

	path := filepath.Join(root, sessionID+".json")
	if err := os.WriteFile(path, []byte(`{"session_id":"`+sessionID+`"}`), 0o644); err != nil {
		t.Fatalf("WriteFile(%s): %v", path, err)
	}
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatalf("Chtimes(%s): %v", path, err)
	}
}

func manifestIDs(manifests []Manifest) []string {
	ids := make([]string, len(manifests))
	for i, manifest := range manifests {
		ids[i] = manifest.SessionID
	}
	return ids
}
