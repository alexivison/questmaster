//go:build linux || darwin

package state

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
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

func TestDeleteArtifactRemovesFileAndEveryLink(t *testing.T) {
	root := setStateRoot(t)
	path := filepath.Join(t.TempDir(), "report.md")
	if err := os.WriteFile(path, []byte("report"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"qm-a", "qm-b"} {
		if err := UpsertArtifactAt(root, id, Artifact{Path: path}); err != nil {
			t.Fatal(err)
		}
	}
	artifacts, err := LoadArtifactsGlobal(root)
	if err != nil {
		t.Fatal(err)
	}
	removed, err := DeleteArtifactAt(root, artifacts[0].ID)
	if err != nil || !removed {
		t.Fatalf("delete = %v, %v", removed, err)
	}
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("file remains: %v", err)
	}
	artifacts, err = LoadArtifactsGlobal(root)
	if err != nil || len(artifacts) != 0 {
		t.Fatalf("registry = %#v, %v", artifacts, err)
	}
	for _, id := range []string{"qm-a", "qm-b"} {
		linked, err := LoadArtifactsAt(root, id)
		if err != nil || len(linked) != 0 {
			t.Fatalf("sidecar %s = %#v, %v", id, linked, err)
		}
	}
}

func TestDeleteArtifactMissingAndDiskFailure(t *testing.T) {
	root := setStateRoot(t)
	missing := filepath.Join(t.TempDir(), "missing.md")
	if err := UpsertArtifactAt(root, "qm-a", Artifact{Path: missing}); err != nil {
		t.Fatal(err)
	}
	if removed, err := DeleteArtifactAt(root, missing); err != nil || !removed {
		t.Fatalf("missing delete = %v, %v", removed, err)
	}
	dir := filepath.Join(t.TempDir(), "directory")
	if err := os.Mkdir(dir, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := UpsertArtifactAt(root, "qm-a", Artifact{Path: dir}); err != nil {
		t.Fatal(err)
	}
	if removed, err := DeleteArtifactAt(root, dir); err == nil || removed {
		t.Fatalf("directory delete = %v, %v", removed, err)
	}
	artifacts, err := LoadArtifactsGlobal(root)
	if err != nil || len(artifacts) != 1 || artifacts[0].Path != dir {
		t.Fatalf("registry after failure = %#v, %v", artifacts, err)
	}
}

func TestDeleteArtifactSymlinkDoesNotFollowTarget(t *testing.T) {
	root := setStateRoot(t)
	target := filepath.Join(t.TempDir(), "target.md")
	link := filepath.Join(t.TempDir(), "link.md")
	if err := os.WriteFile(target, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if err := UpsertArtifactAt(root, "qm-a", Artifact{Path: link}); err != nil {
		t.Fatal(err)
	}
	if removed, err := DeleteArtifactAt(root, link); err != nil || !removed {
		t.Fatalf("symlink delete = %v, %v", removed, err)
	}
	if _, err := os.Lstat(link); !os.IsNotExist(err) {
		t.Fatalf("link remains: %v", err)
	}
	if data, err := os.ReadFile(target); err != nil || string(data) != "keep" {
		t.Fatalf("target = %q, %v", data, err)
	}
}

func TestDeleteArtifactRemovesEmptyManagedDirectory(t *testing.T) {
	root := setStateRoot(t)
	artifact, err := CreateArtifactAt(root, "qm-a", ArtifactCreateOptions{
		Name: "report.md", ProjectID: "project-a", Content: strings.NewReader("report"),
	})
	if err != nil {
		t.Fatal(err)
	}
	dir := filepath.Dir(artifact.Path)
	if removed, err := DeleteArtifactAt(root, artifact.ID); err != nil || !removed {
		t.Fatalf("delete = %v, %v", removed, err)
	}
	if _, err := os.Stat(dir); !os.IsNotExist(err) {
		t.Fatalf("managed directory remains: %v", err)
	}
}

func TestDeleteArtifactRegistryWriteFailureKeepsFile(t *testing.T) {
	root := setStateRoot(t)
	path := filepath.Join(t.TempDir(), "report.md")
	if err := os.WriteFile(path, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := UpsertArtifactAt(root, "qm-a", Artifact{Path: path}); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(ArtifactsRegistryPath(root)+".tmp", 0o700); err != nil {
		t.Fatal(err)
	}
	if removed, err := DeleteArtifactAt(root, path); err == nil || removed {
		t.Fatalf("delete = %v, %v", removed, err)
	}
	if data, err := os.ReadFile(path); err != nil || string(data) != "keep" {
		t.Fatalf("file = %q, %v", data, err)
	}
	artifacts, err := LoadArtifactsGlobal(root)
	if err != nil || len(artifacts) != 1 {
		t.Fatalf("registry = %#v, %v", artifacts, err)
	}
}

func TestDeleteArtifactSidecarWriteFailureRestoresFileAndLinks(t *testing.T) {
	root := setStateRoot(t)
	path := filepath.Join(t.TempDir(), "shared.md")
	if err := os.WriteFile(path, []byte("keep"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"qm-a", "qm-b"} {
		if err := os.MkdirAll(SessionStateDir(root, id), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := UpsertArtifactAt(root, id, Artifact{Path: path}); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Mkdir(SessionArtifactsPath(root, "qm-b")+".tmp", 0o700); err != nil {
		t.Fatal(err)
	}
	removed, err := DeleteArtifactAt(root, path)
	if err == nil || removed {
		t.Fatalf("delete = %v, %v; want failure without deletion", removed, err)
	}
	if data, err := os.ReadFile(path); err != nil || string(data) != "keep" {
		t.Fatalf("file = %q, %v", data, err)
	}
	artifacts, err := LoadArtifactsGlobal(root)
	if err != nil || len(artifacts) != 1 || !reflect.DeepEqual(artifacts[0].SessionIDs, []string{"qm-a", "qm-b"}) {
		t.Fatalf("registry = %#v, %v", artifacts, err)
	}
	for _, id := range []string{"qm-a", "qm-b"} {
		sidecar, exists, err := loadArtifactsSidecarAt(root, id)
		if err != nil || !exists || len(sidecar) != 1 || sidecar[0].Path != path {
			t.Fatalf("sidecar %s = %#v, %v, %v", id, sidecar, exists, err)
		}
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
