//go:build linux || darwin

package cmd

import (
	"bytes"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func TestArtifactCreateFromStdinAndImport(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-create")
	project := t.TempDir()
	if err := os.Mkdir(filepath.Join(project, ".git"), 0o755); err != nil {
		t.Fatal(err)
	}
	createManifest(t, store, "qm-create", "create", project, "regular")

	out := runCmdInput(t, store, sessionsRunner(), strings.NewReader("# Report\n"), "artifact", "create", "report.md", "--label", "Report")
	artifacts, err := state.LoadArtifactsAt(store.Root(), "qm-create")
	if err != nil || len(artifacts) != 1 {
		t.Fatalf("created: %#v, %v", artifacts, err)
	}
	report := artifacts[0]
	if report.ID == "" || report.Label != "Report" || report.Kind != state.ArtifactKindMarkdown || !strings.Contains(out, report.ID) || !strings.Contains(out, report.Path) {
		t.Fatalf("created report or output: %#v, %q", report, out)
	}
	if !strings.HasPrefix(report.Path, filepath.Join(store.Root(), "artifact-files")+string(os.PathSeparator)) || strings.Contains(report.Path, "qm-create") {
		t.Fatalf("managed path = %q", report.Path)
	}
	body, err := os.ReadFile(report.Path)
	if err != nil || string(body) != "# Report\n" {
		t.Fatalf("report bytes = %q, %v", body, err)
	}

	source := filepath.Join(t.TempDir(), "diagram.png")
	image := []byte{0x89, 0x50, 0x4e, 0x47, 0x00, 0xff}
	if err := os.WriteFile(source, image, 0o600); err != nil {
		t.Fatal(err)
	}
	runCmd(t, store, sessionsRunner(), "artifact", "create", "diagram.png", "--from", source)
	artifacts, err = state.LoadArtifactsAt(store.Root(), "qm-create")
	if err != nil || len(artifacts) != 2 {
		t.Fatalf("after import: %#v, %v", artifacts, err)
	}
	var imported state.Artifact
	for _, artifact := range artifacts {
		if artifact.Kind == state.ArtifactKindImage {
			imported = artifact
		}
	}
	if imported.Path == source || imported.Path == "" {
		t.Fatalf("import path = %q", imported.Path)
	}
	copied, err := os.ReadFile(imported.Path)
	if err != nil || !bytes.Equal(copied, image) {
		t.Fatalf("image bytes = %v, %v", copied, err)
	}
	original, err := os.ReadFile(source)
	if err != nil || !bytes.Equal(original, image) {
		t.Fatalf("source was changed: %v, %v", original, err)
	}
}

func TestArtifactCreateInfersProject(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-project")
	sessionRepo := t.TempDir()
	sourceRepo := t.TempDir()
	for _, root := range []string{sessionRepo, sourceRepo} {
		if err := os.Mkdir(filepath.Join(root, ".git"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	createManifest(t, store, "qm-project", "project", sessionRepo, "regular")
	runCmdInput(t, store, sessionsRunner(), strings.NewReader("text"), "artifact", "create", "note.md")
	source := filepath.Join(sourceRepo, "report.html")
	if err := os.WriteFile(source, []byte("<h1>Report</h1>"), 0o600); err != nil {
		t.Fatal(err)
	}
	runCmd(t, store, sessionsRunner(), "artifact", "create", "report.html", "--from", source)
	artifacts, err := state.LoadArtifactsAt(store.Root(), "qm-project")
	if err != nil || len(artifacts) != 2 {
		t.Fatalf("artifacts: %#v, %v", artifacts, err)
	}
	for _, artifact := range artifacts {
		wantRepo := sessionRepo
		if artifact.Label == "report.html" {
			wantRepo = sourceRepo
		}
		wantID, err := filepath.EvalSymlinks(filepath.Join(wantRepo, ".git"))
		if err != nil {
			t.Fatal(err)
		}
		if artifact.ProjectID != wantID {
			t.Fatalf("%s project = %q, want %q", artifact.Label, artifact.ProjectID, wantID)
		}
	}
}

func TestArtifactCreateRejectsInvalidNameAndCleansFailure(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-failure")
	if _, err := runCmdInputErr(t, store, sessionsRunner(), strings.NewReader("x"), "artifact", "create", "../escape.html"); err == nil {
		t.Fatal("path traversal name accepted")
	}
	if err := os.Mkdir(state.ArtifactsRegistryPath(store.Root()), 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := runCmdInputErr(t, store, sessionsRunner(), strings.NewReader("x"), "artifact", "create", "safe.html"); err == nil {
		t.Fatal("registry failure was ignored")
	}
	entries, err := os.ReadDir(filepath.Join(store.Root(), "artifact-files"))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("managed files remain after failure: %#v", entries)
	}
}

func TestArtifactCreateRollsBackAfterSidecarFailure(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-sidecar-fail")
	if err := state.SaveSessionState("qm-sidecar-fail", &state.SessionState{SessionID: "qm-sidecar-fail", Version: state.SchemaVersion, Panes: map[string]state.PaneState{}}); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(state.SessionArtifactsPath(store.Root(), "qm-sidecar-fail")+".tmp", 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := runCmdInputErr(t, store, sessionsRunner(), strings.NewReader("content"), "artifact", "create", "report.md"); err == nil {
		t.Fatal("sidecar failure was ignored")
	}
	artifacts, err := state.LoadArtifactsGlobal(store.Root())
	if err != nil {
		t.Fatal(err)
	}
	if len(artifacts) != 0 {
		t.Fatalf("failed create left registration: %#v", artifacts)
	}
	entries, err := os.ReadDir(filepath.Join(store.Root(), "artifact-files"))
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	if len(entries) != 0 {
		t.Fatalf("failed create left files: %#v", entries)
	}
}

func TestArtifactAddLinksIDWithoutCopy(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-first")
	path := filepath.Join(t.TempDir(), "shared.html")
	if err := os.WriteFile(path, []byte("<h1>Shared</h1>"), 0o600); err != nil {
		t.Fatal(err)
	}
	runCmd(t, store, sessionsRunner(), "artifact", "add", path, "--label", "Shared")
	before, err := state.LoadArtifactsGlobal(store.Root())
	if err != nil || len(before) != 1 {
		t.Fatalf("before: %#v, %v", before, err)
	}
	runCmd(t, store, sessionsRunner(), "artifact", "add", before[0].ID, "--session", "qm-second")
	after, err := state.LoadArtifactsGlobal(store.Root())
	if err != nil || len(after) != 1 {
		t.Fatalf("after: %#v, %v", after, err)
	}
	if after[0].ID != before[0].ID || after[0].Path != path || !reflect.DeepEqual(after[0].SessionIDs, []string{"qm-first", "qm-second"}) || after[0].Label != "Shared" {
		t.Fatalf("link changed artifact: %#v", after[0])
	}
	runCmd(t, store, sessionsRunner(), "artifact", "add", before[0].ID, "--session", "qm-second")
	repeated, err := state.LoadArtifactsGlobal(store.Root())
	if err != nil || !reflect.DeepEqual(after, repeated) {
		t.Fatalf("repeated link changed record: before=%#v after=%#v err=%v", after, repeated, err)
	}
}
