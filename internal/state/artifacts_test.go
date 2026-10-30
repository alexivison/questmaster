//go:build linux || darwin

package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
)

func TestArtifactLinksRemainAfterSecondSessionAdd(t *testing.T) {
	root := setStateRoot(t)
	path := filepath.Join(t.TempDir(), "report.html")
	if err := UpsertArtifactAt(root, "qm-alpha", Artifact{Path: path, Label: "Report", Kind: ArtifactKindHTML, ProjectID: "repo-a", AddedAt: "2026-06-19T04:20:00Z"}); err != nil {
		t.Fatal(err)
	}
	before, err := LoadArtifactsGlobal(root)
	if err != nil || len(before) != 1 {
		t.Fatalf("first load: %#v, %v", before, err)
	}
	if err := UpsertArtifactAt(root, "qm-beta", Artifact{Path: path}); err != nil {
		t.Fatal(err)
	}
	after, err := LoadArtifactsGlobal(root)
	if err != nil || len(after) != 1 {
		t.Fatalf("second load: %#v, %v", after, err)
	}
	got := after[0]
	if got.ID == "" || got.ID != before[0].ID {
		t.Fatalf("artifact ID changed: before=%q after=%q", before[0].ID, got.ID)
	}
	if !reflect.DeepEqual(got.SessionIDs, []string{"qm-alpha", "qm-beta"}) {
		t.Fatalf("links = %#v", got.SessionIDs)
	}
	if got.CreatedBySessionID != "qm-alpha" || got.Label != "Report" || got.ProjectID != "repo-a" || got.AddedAt != "2026-06-19T04:20:00Z" {
		t.Fatalf("metadata changed on link: %#v", got)
	}
	if found, ok := ArtifactByIDOrPath(after, got.ID); !ok || found.Path != path {
		t.Fatalf("lookup by ID = %#v, %v", found, ok)
	}
	if session := FilterArtifacts(after, ArtifactScopeSession, "qm-alpha", ""); len(session) != 1 {
		t.Fatalf("alpha scope = %#v", session)
	}
	if session := FilterArtifacts(after, ArtifactScopeSession, "qm-beta", ""); len(session) != 1 {
		t.Fatalf("beta scope = %#v", session)
	}
}

func TestArtifactGlobalUpsertKeepsSessionLinks(t *testing.T) {
	root := setStateRoot(t)
	path := filepath.Join(t.TempDir(), "report.html")
	for _, id := range []string{"qm-a", "qm-b"} {
		if err := UpsertArtifactAt(root, id, Artifact{Path: path}); err != nil {
			t.Fatal(err)
		}
	}
	if err := UpsertArtifactGlobal(root, Artifact{Path: path, Label: "Renamed"}); err != nil {
		t.Fatal(err)
	}
	artifacts, err := LoadArtifactsGlobal(root)
	if err != nil || len(artifacts) != 1 {
		t.Fatalf("load: %#v, %v", artifacts, err)
	}
	if !reflect.DeepEqual(artifacts[0].SessionIDs, []string{"qm-a", "qm-b"}) {
		t.Fatalf("global upsert lost links: %#v", artifacts[0])
	}
}

func TestArtifactConcurrentLinks(t *testing.T) {
	root := setStateRoot(t)
	path := filepath.Join(t.TempDir(), "shared.md")
	ids := []string{"qm-a", "qm-b", "qm-c", "qm-d", "qm-e", "qm-f"}
	var wg sync.WaitGroup
	errors := make(chan error, len(ids))
	for _, id := range ids {
		wg.Add(1)
		go func() {
			defer wg.Done()
			errors <- UpsertArtifactAt(root, id, Artifact{Path: path})
		}()
	}
	wg.Wait()
	close(errors)
	for err := range errors {
		if err != nil {
			t.Fatal(err)
		}
	}
	artifacts, err := LoadArtifactsGlobal(root)
	if err != nil || len(artifacts) != 1 {
		t.Fatalf("load: %#v, %v", artifacts, err)
	}
	if !reflect.DeepEqual(artifacts[0].SessionIDs, ids) {
		t.Fatalf("links = %#v, want %#v", artifacts[0].SessionIDs, ids)
	}
}

func TestArtifactUnlinkPreservesOtherSessions(t *testing.T) {
	root := setStateRoot(t)
	path := filepath.Join(t.TempDir(), "shared.png")
	for _, id := range []string{"qm-a", "qm-b"} {
		if err := SaveSessionState(id, &SessionState{SessionID: id, Version: SchemaVersion, Panes: map[string]PaneState{}}); err != nil {
			t.Fatal(err)
		}
		if err := UpsertArtifactAt(root, id, Artifact{Path: path}); err != nil {
			t.Fatal(err)
		}
	}
	removed, err := RemoveArtifactAt(root, "qm-a", path)
	if err != nil || !removed {
		t.Fatalf("unlink: %v, %v", removed, err)
	}
	artifacts, err := LoadArtifactsGlobal(root)
	if err != nil || len(artifacts) != 1 {
		t.Fatalf("load: %#v, %v", artifacts, err)
	}
	if !reflect.DeepEqual(artifacts[0].SessionIDs, []string{"qm-b"}) {
		t.Fatalf("links = %#v", artifacts[0].SessionIDs)
	}
	for id, want := range map[string]int{"qm-a": 0, "qm-b": 1} {
		sidecar, _, err := loadArtifactsSidecarAt(root, id)
		if err != nil || len(sidecar) != want {
			t.Fatalf("%s sidecar: %#v, %v", id, sidecar, err)
		}
	}
}

func TestArtifactLegacyRegistryAndSidecarMigration(t *testing.T) {
	t.Run("root registry", func(t *testing.T) {
		root := setStateRoot(t)
		path := filepath.Join(t.TempDir(), "legacy.html")
		data, err := json.Marshal(artifactSidecar{Artifacts: []Artifact{{Path: path, SessionID: "qm-old", Label: "Legacy", ProjectID: "repo-a", AddedAt: "2026-06-19T04:20:00Z"}}})
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(ArtifactsRegistryPath(root), data, 0o600); err != nil {
			t.Fatal(err)
		}
		first, err := LoadArtifactsGlobal(root)
		if err != nil || len(first) != 1 {
			t.Fatalf("load: %#v, %v", first, err)
		}
		second, err := LoadArtifactsGlobal(root)
		if err != nil || len(second) != 1 {
			t.Fatalf("reload: %#v, %v", second, err)
		}
		got := first[0]
		if got.ID == "" || second[0].ID != got.ID || !reflect.DeepEqual(got.SessionIDs, []string{"qm-old"}) || got.Label != "Legacy" || got.ProjectID != "repo-a" || got.Path != path {
			t.Fatalf("migrated = %#v, second = %#v", got, second[0])
		}
	})
	t.Run("two sidecars", func(t *testing.T) {
		root := setStateRoot(t)
		path := filepath.Join(t.TempDir(), "shared.html")
		for _, id := range []string{"qm-a", "qm-b"} {
			if err := writeArtifactsLocked(root, id, []Artifact{{Path: path, Label: "Shared", SessionID: id, AddedAt: "2026-06-19T04:20:00Z"}}); err != nil {
				t.Fatal(err)
			}
		}
		got, err := LoadArtifactsGlobal(root)
		if err != nil || len(got) != 1 {
			t.Fatalf("migration: %#v, %v", got, err)
		}
		if !reflect.DeepEqual(got[0].SessionIDs, []string{"qm-a", "qm-b"}) {
			t.Fatalf("migrated links = %#v", got[0].SessionIDs)
		}
	})
}
