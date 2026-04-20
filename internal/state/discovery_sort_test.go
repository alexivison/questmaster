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
		{PartyID: "party-old"},
		{PartyID: "party-tie-a"},
		{PartyID: "party-tie-b"},
		{PartyID: "party-new"},
	}

	setManifestMtime(t, root, "party-old", time.Unix(10, 0))
	setManifestMtime(t, root, "party-tie-a", time.Unix(20, 0))
	setManifestMtime(t, root, "party-tie-b", time.Unix(20, 0))
	setManifestMtime(t, root, "party-new", time.Unix(30, 0))

	SortByMtime(manifests, root)

	got := manifestIDs(manifests)
	want := []string{"party-new", "party-tie-a", "party-tie-b", "party-old"}
	if !slices.Equal(got, want) {
		t.Fatalf("sorted ids: got %v, want %v", got, want)
	}
}

func TestSortByMtime_PreservesInputOrderWhenAllMtimesMatch(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	manifests := []Manifest{
		{PartyID: "party-c"},
		{PartyID: "party-a"},
		{PartyID: "party-b"},
	}

	mtime := time.Unix(42, 0)
	for _, manifest := range manifests {
		setManifestMtime(t, root, manifest.PartyID, mtime)
	}

	SortByMtime(manifests, root)

	got := manifestIDs(manifests)
	want := []string{"party-c", "party-a", "party-b"}
	if !slices.Equal(got, want) {
		t.Fatalf("sorted ids: got %v, want %v", got, want)
	}
}

func setManifestMtime(t *testing.T, root, partyID string, mtime time.Time) {
	t.Helper()

	path := filepath.Join(root, partyID+".json")
	if err := os.WriteFile(path, []byte(`{"party_id":"`+partyID+`"}`), 0o644); err != nil {
		t.Fatalf("WriteFile(%s): %v", path, err)
	}
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatalf("Chtimes(%s): %v", path, err)
	}
}

func manifestIDs(manifests []Manifest) []string {
	ids := make([]string, len(manifests))
	for i, manifest := range manifests {
		ids[i] = manifest.PartyID
	}
	return ids
}
