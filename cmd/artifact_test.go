//go:build linux || darwin

package cmd

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/state"
)

func TestArtifactAddListRemove(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-artifacts")
	workdir := t.TempDir()
	t.Chdir(workdir)

	if err := os.MkdirAll("docs", 0o755); err != nil {
		t.Fatalf("mkdir docs: %v", err)
	}
	planPath := filepath.Join(workdir, "docs", "plan.html")
	if err := os.WriteFile(planPath, []byte("<h1>Plan</h1>"), 0o644); err != nil {
		t.Fatalf("write artifact: %v", err)
	}

	out := runCmd(t, store, sessionsRunner(), "artifact", "add", "docs/plan.html", "--label", "Plan")
	if !strings.Contains(out, "qm-artifacts") || !strings.Contains(out, planPath) {
		t.Fatalf("add output = %q, want session and absolute path", out)
	}
	first, err := state.LoadArtifacts("qm-artifacts")
	if err != nil {
		t.Fatalf("load artifacts after add: %v", err)
	}
	if len(first) != 1 {
		t.Fatalf("artifacts after add = %#v, want one", first)
	}
	if first[0].Path != planPath || first[0].Kind != "html" || first[0].Label != "Plan" {
		t.Fatalf("artifact after add = %#v", first[0])
	}
	firstAddedAt := first[0].AddedAt
	if _, err := time.Parse(time.RFC3339Nano, firstAddedAt); err != nil {
		t.Fatalf("added_at = %q, want RFC3339 timestamp: %v", firstAddedAt, err)
	}

	runCmd(t, store, sessionsRunner(), "artifact", "add", "docs/plan.html", "--label", "Plan v2")
	afterUpsert, err := state.LoadArtifacts("qm-artifacts")
	if err != nil {
		t.Fatalf("load artifacts after upsert: %v", err)
	}
	if len(afterUpsert) != 1 {
		t.Fatalf("artifacts after upsert = %#v, want deduped", afterUpsert)
	}
	if afterUpsert[0].Label != "Plan v2" || afterUpsert[0].AddedAt == firstAddedAt {
		t.Fatalf("artifact after upsert = %#v, want updated label and added_at", afterUpsert[0])
	}

	if err := state.SaveSessionState("qm-artifacts", &state.SessionState{
		SessionID: "qm-artifacts",
		Version:   state.SchemaVersion,
		Panes:     map[string]state.PaneState{"agent": {Role: "agent", State: "working"}},
	}); err != nil {
		t.Fatalf("simulate old hook rewrite: %v", err)
	}

	missingPath := filepath.Join(workdir, "docs", "missing.html")
	runCmd(t, store, sessionsRunner(), "artifact", "add", "docs/missing.html")
	listOut := runCmd(t, store, sessionsRunner(), "artifact", "ls", "--session", "qm-artifacts")
	lines := strings.Split(strings.TrimSpace(listOut), "\n")
	if len(lines) != 2 {
		t.Fatalf("ls output = %q, want two artifacts", listOut)
	}
	if !strings.Contains(lines[0], "missing") || !strings.Contains(lines[0], "missing.html") || !strings.Contains(lines[0], missingPath) {
		t.Fatalf("newest missing line = %q", lines[0])
	}
	if !strings.Contains(lines[1], "ok") || !strings.Contains(lines[1], "Plan v2") || !strings.Contains(lines[1], planPath) {
		t.Fatalf("existing artifact line = %q", lines[1])
	}

	runCmd(t, store, sessionsRunner(), "artifact", "rm", "1", "--session", "qm-artifacts")
	afterIndexRemove, err := state.LoadArtifacts("qm-artifacts")
	if err != nil {
		t.Fatalf("load artifacts after index remove: %v", err)
	}
	if len(afterIndexRemove) != 1 || afterIndexRemove[0].Path != planPath {
		t.Fatalf("artifacts after index remove = %#v, want only plan", afterIndexRemove)
	}

	runCmd(t, store, sessionsRunner(), "artifact", "rm", "docs/plan.html", "--session", "qm-artifacts")
	afterPathRemove, err := state.LoadArtifacts("qm-artifacts")
	if err != nil {
		t.Fatalf("load artifacts after path remove: %v", err)
	}
	if len(afterPathRemove) != 0 {
		t.Fatalf("artifacts after path remove = %#v, want none", afterPathRemove)
	}
}

func TestArtifactDeleteRemovesFileAndAllLinks(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	path := filepath.Join(t.TempDir(), "shared.md")
	if err := os.WriteFile(path, []byte("shared"), 0o600); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"qm-first", "qm-second"} {
		if err := state.UpsertArtifactAt(store.Root(), id, state.Artifact{Path: path}); err != nil {
			t.Fatal(err)
		}
	}
	artifacts, err := state.LoadArtifactsGlobal(store.Root())
	if err != nil {
		t.Fatal(err)
	}
	runCmd(t, store, sessionsRunner(), "artifact", "delete", artifacts[0].ID)
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("file remains: %v", err)
	}
	artifacts, err = state.LoadArtifactsGlobal(store.Root())
	if err != nil || len(artifacts) != 0 {
		t.Fatalf("registry = %#v, %v", artifacts, err)
	}
}

func TestArtifactRemoveUsesRequestedSessionForSharedArtifact(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	path := filepath.Join(t.TempDir(), "shared.md")
	for _, id := range []string{"qm-a", "qm-b"} {
		if err := state.UpsertArtifactAt(store.Root(), id, state.Artifact{Path: path}); err != nil {
			t.Fatal(err)
		}
	}
	runCmd(t, store, sessionsRunner(), "artifact", "rm", path, "--session", "qm-b")
	artifacts, err := state.LoadArtifactsGlobal(store.Root())
	if err != nil || len(artifacts) != 1 {
		t.Fatalf("registry = %#v, %v", artifacts, err)
	}
	if !reflect.DeepEqual(artifacts[0].SessionIDs, []string{"qm-a"}) {
		t.Fatalf("wrong session unlinked: %#v", artifacts[0].SessionIDs)
	}
}

func TestArtifactAddAcceptsRelativeFileStartingWithArt(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-art-prefix")
	t.Chdir(t.TempDir())
	if err := os.WriteFile("art-report.md", []byte("report"), 0o600); err != nil {
		t.Fatal(err)
	}
	runCmd(t, store, sessionsRunner(), "artifact", "add", "art-report.md")
	artifacts, err := state.LoadArtifactsAt(store.Root(), "qm-art-prefix")
	if err != nil || len(artifacts) != 1 {
		t.Fatalf("registered = %#v, %v", artifacts, err)
	}
}

func TestArtifactAddWithoutMetadataIsIdempotent(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-idempotent")
	path := filepath.Join(t.TempDir(), "report.md")
	if err := os.WriteFile(path, []byte("report"), 0o600); err != nil {
		t.Fatal(err)
	}
	runCmd(t, store, sessionsRunner(), "artifact", "add", path, "--label", "Report")
	before, err := state.LoadArtifactsGlobal(store.Root())
	if err != nil {
		t.Fatal(err)
	}
	runCmd(t, store, sessionsRunner(), "artifact", "add", path)
	after, err := state.LoadArtifactsGlobal(store.Root())
	if err != nil || !reflect.DeepEqual(after, before) {
		t.Fatalf("re-add changed artifact: before=%#v after=%#v, %v", before, after, err)
	}
}

func TestArtifactAddUnknownIDDoesNotRegisterMissingPath(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-unknown-id")
	unknownID := "art-0123456789abcdef0123456789abcdef"
	if _, err := runCmdInputErr(t, store, sessionsRunner(), strings.NewReader(""), "artifact", "add", unknownID); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("unknown ID error = %v", err)
	}
	artifacts, err := state.LoadArtifactsGlobal(store.Root())
	if err != nil || len(artifacts) != 0 {
		t.Fatalf("registry = %#v, %v", artifacts, err)
	}
}

func TestArtifactDeleteAcceptsRelativePath(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Chdir(t.TempDir())
	if err := os.WriteFile("report.md", []byte("report"), 0o600); err != nil {
		t.Fatal(err)
	}
	path, err := filepath.Abs("report.md")
	if err != nil {
		t.Fatal(err)
	}
	if err := state.UpsertArtifactAt(store.Root(), "qm-a", state.Artifact{Path: path}); err != nil {
		t.Fatal(err)
	}
	runCmd(t, store, sessionsRunner(), "artifact", "delete", "report.md")
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("file remains: %v", err)
	}
}

func TestArtifactAddInfersAndOverridesKind(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-artifact-kind")
	workdir := t.TempDir()
	t.Chdir(workdir)

	if err := os.WriteFile("report.md", []byte("# Report"), 0o644); err != nil {
		t.Fatalf("write markdown artifact: %v", err)
	}
	if err := os.WriteFile("diagram.png", []byte("not really a png"), 0o644); err != nil {
		t.Fatalf("write image artifact: %v", err)
	}

	runCmd(t, store, sessionsRunner(), "artifact", "add", "report.md")
	runCmd(t, store, sessionsRunner(), "artifact", "add", "diagram.png", "--kind", "html")

	artifacts, err := state.LoadArtifacts("qm-artifact-kind")
	if err != nil {
		t.Fatalf("load artifacts: %v", err)
	}

	kinds := map[string]string{}
	for _, artifact := range artifacts {
		kinds[filepath.Base(artifact.Path)] = artifact.Kind
	}
	if kinds["report.md"] != state.ArtifactKindMarkdown {
		t.Fatalf("report.md kind = %q, want markdown", kinds["report.md"])
	}
	if kinds["diagram.png"] != state.ArtifactKindHTML {
		t.Fatalf("diagram.png kind = %q, want override html", kinds["diagram.png"])
	}
}

func TestArtifactAddSetsProjectIDFromSessionManifestCwd(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-artifact-project")
	workdir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(workdir, ".git"), 0o755); err != nil {
		t.Fatalf("mkdir .git: %v", err)
	}
	createManifest(t, store, "qm-artifact-project", "project", workdir, "regular")
	t.Chdir(workdir)

	if err := os.WriteFile("plan.html", []byte("<h1>Plan</h1>"), 0o644); err != nil {
		t.Fatalf("write artifact: %v", err)
	}
	runCmd(t, store, sessionsRunner(), "artifact", "add", "plan.html")

	artifacts, err := state.LoadArtifactsGlobal(store.Root())
	if err != nil {
		t.Fatalf("load global artifacts: %v", err)
	}
	if len(artifacts) != 1 {
		t.Fatalf("artifacts = %#v, want one", artifacts)
	}
	wantProjectID, err := filepath.EvalSymlinks(filepath.Join(workdir, ".git"))
	if err != nil {
		t.Fatalf("resolve .git: %v", err)
	}
	if artifacts[0].SessionID != "qm-artifact-project" || artifacts[0].ProjectID != wantProjectID {
		t.Fatalf("artifact = %#v, want session and project ids", artifacts[0])
	}
}

func TestArtifactProjectScopeListAndRemoveSyncsOwningSidecar(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-scope-current")
	workdir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(workdir, ".git"), 0o755); err != nil {
		t.Fatalf("mkdir .git: %v", err)
	}
	projectID, err := filepath.EvalSymlinks(filepath.Join(workdir, ".git"))
	if err != nil {
		t.Fatalf("resolve .git: %v", err)
	}
	createManifest(t, store, "qm-scope-current", "current", workdir, "regular")
	if err := state.SaveSessionState("qm-scope-peer", &state.SessionState{
		SessionID: "qm-scope-peer",
		Version:   state.SchemaVersion,
		Panes:     map[string]state.PaneState{},
	}); err != nil {
		t.Fatalf("create peer session state dir: %v", err)
	}

	currentPath := writeArtifactFile(t, workdir, "current.html")
	peerPath := writeArtifactFile(t, workdir, "peer.html")
	outsidePath := writeArtifactFile(t, workdir, "outside.html")
	root := store.Root()
	for _, artifact := range []state.Artifact{
		{Path: currentPath, Label: "Current", ProjectID: projectID, AddedAt: "2026-06-19T04:19:00Z"},
		{Path: peerPath, Label: "Peer", ProjectID: projectID, AddedAt: "2026-06-19T04:21:00Z"},
		{Path: outsidePath, Label: "Outside", ProjectID: "other-project", AddedAt: "2026-06-19T04:20:00Z"},
	} {
		sessionID := "qm-scope-current"
		if artifact.Path == peerPath {
			sessionID = "qm-scope-peer"
		}
		if artifact.Path == outsidePath {
			sessionID = "qm-scope-outside"
		}
		if err := state.UpsertArtifactAt(root, sessionID, artifact); err != nil {
			t.Fatalf("seed artifact %s: %v", artifact.Path, err)
		}
	}

	out := runCmd(t, store, sessionsRunner(), "artifact", "ls", "--scope", "project")
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if len(lines) != 2 || !strings.Contains(out, "peer.html") || !strings.Contains(out, "current.html") || strings.Contains(out, "outside.html") {
		t.Fatalf("project ls output = %q, want current and peer only", out)
	}

	runCmd(t, store, sessionsRunner(), "artifact", "rm", "1", "--scope", "project")
	artifacts, err := state.LoadArtifactsGlobal(root)
	if err != nil {
		t.Fatalf("load global artifacts: %v", err)
	}
	for _, artifact := range artifacts {
		if artifact.Path == peerPath {
			t.Fatalf("peer artifact still present after scoped rm: %#v", artifacts)
		}
	}
	sidecar := loadArtifactSidecar(t, root, "qm-scope-peer")
	if len(sidecar) != 0 {
		t.Fatalf("peer sidecar = %#v, want empty after scoped rm", sidecar)
	}
}

func TestArtifactAllScopeRemoveDoesNotRecreateDeletedOwnerDir(t *testing.T) {
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	t.Setenv(state.SessionEnv, "qm-scope-current")
	root := store.Root()
	ownerID := "qm-scope-deleted"
	path := filepath.Join(t.TempDir(), "deleted.html")
	if err := os.WriteFile(path, []byte("<h1>deleted</h1>"), 0o644); err != nil {
		t.Fatalf("write artifact: %v", err)
	}
	if err := state.SaveSessionState(ownerID, &state.SessionState{
		SessionID: ownerID,
		Version:   state.SchemaVersion,
		Panes:     map[string]state.PaneState{},
	}); err != nil {
		t.Fatalf("create owner session state dir: %v", err)
	}
	if err := state.UpsertArtifactAt(root, ownerID, state.Artifact{
		Path:    path,
		Label:   "Deleted",
		AddedAt: "2026-06-19T04:19:00Z",
	}); err != nil {
		t.Fatalf("seed artifact: %v", err)
	}
	if err := os.RemoveAll(state.SessionStateDir(root, ownerID)); err != nil {
		t.Fatalf("remove owner state dir: %v", err)
	}

	runCmd(t, store, sessionsRunner(), "artifact", "rm", "1", "--scope", "all")

	artifacts, err := state.LoadArtifactsGlobal(root)
	if err != nil {
		t.Fatalf("load global artifacts: %v", err)
	}
	if len(artifacts) != 0 {
		t.Fatalf("artifacts = %#v, want registry empty", artifacts)
	}
	if _, err := os.Stat(state.SessionStateDir(root, ownerID)); !os.IsNotExist(err) {
		t.Fatalf("owner session state dir recreated: err=%v", err)
	}
}

func writeArtifactFile(t *testing.T, dir, name string) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte("<h1>"+name+"</h1>"), 0o644); err != nil {
		t.Fatalf("write artifact %s: %v", name, err)
	}
	return path
}

func loadArtifactSidecar(t *testing.T, root, sessionID string) []state.Artifact {
	t.Helper()
	data, err := os.ReadFile(state.SessionArtifactsPath(root, sessionID))
	if err != nil {
		t.Fatalf("read sidecar: %v", err)
	}
	var payload struct {
		Artifacts []state.Artifact `json:"artifacts,omitempty"`
	}
	if err := json.Unmarshal(data, &payload); err != nil {
		t.Fatalf("decode sidecar: %v", err)
	}
	return payload.Artifacts
}
