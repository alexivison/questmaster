//go:build linux || darwin

package serve

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

func newProjectTestServer(t *testing.T) (*Server, *state.Store) {
	t.Helper()
	store := state.OpenStore(t.TempDir())
	return &Server{Snapshotter: &Snapshotter{store: store}}, store
}

// resolvedProjectTempDir resolves symlinks so the paths a test expects match
// the IDs the server stores (macOS temp dirs live behind /var -> /private/var).
func resolvedProjectTempDir(t *testing.T) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatalf("resolve temp dir: %v", err)
	}
	return resolved
}

func mkProjectFolder(t *testing.T, path string) string {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
	return path
}

func mustProjectJSON(t *testing.T, value map[string]any) json.RawMessage {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("marshal %#v: %v", value, err)
	}
	return raw
}

func addProjectFolder(t *testing.T, server *Server, path, name, color string) ProjectSnapshot {
	t.Helper()
	got, err := server.mutateProjectAdd(mutationPayload{Path: path, Name: name, Color: color})
	if err != nil {
		t.Fatalf("project add %s: %v", path, err)
	}
	return got.(ProjectSnapshot)
}

func projectIDs(t *testing.T, server *Server) []string {
	t.Helper()
	projects, err := server.knownProjects()
	if err != nil {
		t.Fatalf("known projects: %v", err)
	}
	ids := make([]string, 0, len(projects))
	for _, project := range projects {
		ids = append(ids, project.ID)
	}
	return ids
}

func TestProjectAddRegistersFolderWithNameAndColor(t *testing.T) {
	t.Parallel()

	server, store := newProjectTestServer(t)
	folder := mkProjectFolder(t, filepath.Join(resolvedProjectTempDir(t), "notes"))

	got := addProjectFolder(t, server, folder, "Scratch", "Green")

	want := ProjectSnapshot{ID: folder, Name: "Scratch", DefaultName: "notes", Path: folder, Color: "green"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("added project = %#v, want %#v", got, want)
	}
	if rc, ok, err := state.NewRepoColorStore(store.Root()).Get(folder); err != nil || !ok || rc.Color != "green" {
		t.Fatalf("stored color = %#v, %v, %v; want green under the folder ID", rc, ok, err)
	}
	if ids := projectIDs(t, server); !reflect.DeepEqual(ids, []string{folder}) {
		t.Fatalf("known projects = %v, want the added folder with no sessions", ids)
	}
}

func TestProjectAddRepoRootUsesRepoIdentity(t *testing.T) {
	t.Parallel()

	server, _ := newProjectTestServer(t)
	repoRoot := resolvedProjectTempDir(t)
	mkProjectFolder(t, filepath.Join(repoRoot, ".git"))

	got := addProjectFolder(t, server, repoRoot, "", "")

	if want := filepath.Join(repoRoot, ".git"); got.ID != want || got.Path != repoRoot {
		t.Fatalf("repo root project = %q at %q, want %q at %q", got.ID, got.Path, want, repoRoot)
	}
}

func TestProjectAddKnownProjectAppliesNameAndColorAgain(t *testing.T) {
	t.Parallel()

	server, _ := newProjectTestServer(t)
	folder := mkProjectFolder(t, filepath.Join(resolvedProjectTempDir(t), "notes"))
	addProjectFolder(t, server, folder, "", "")

	got := addProjectFolder(t, server, folder, "Renamed", "blue")

	if got.ID != folder || got.Name != "Renamed" || got.Color != "blue" {
		t.Fatalf("re-added project = %#v, want the same project renamed and recolored", got)
	}
	if ids := projectIDs(t, server); len(ids) != 1 {
		t.Fatalf("known projects = %v, want one entry", ids)
	}
}

func TestProjectAddRejectsUnusablePaths(t *testing.T) {
	t.Parallel()

	server, _ := newProjectTestServer(t)
	base := resolvedProjectTempDir(t)
	file := filepath.Join(base, "readme.txt")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}
	tests := []struct {
		name string
		path string
	}{
		{name: "empty", path: ""},
		{name: "relative", path: "notes"},
		{name: "missing", path: filepath.Join(base, "missing")},
		{name: "file", path: file},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if _, err := server.mutateProjectAdd(mutationPayload{Path: tt.path}); err == nil {
				t.Fatalf("project add %q succeeded, want an error", tt.path)
			}
		})
	}
}

func TestProjectUpdateTreatsAbsentFieldsDifferentlyFromEmptyOnes(t *testing.T) {
	t.Parallel()

	server, _ := newProjectTestServer(t)
	folder := mkProjectFolder(t, filepath.Join(resolvedProjectTempDir(t), "notes"))
	addProjectFolder(t, server, folder, "Notes", "green")

	steps := []struct {
		name string
		body map[string]any
		want ProjectSnapshot
	}{
		{
			name: "absent name keeps the override",
			body: map[string]any{"project_id": folder, "color": "blue"},
			want: ProjectSnapshot{ID: folder, Name: "Notes", DefaultName: "notes", Path: folder, Color: "blue"},
		},
		{
			name: "empty name clears the override",
			body: map[string]any{"project_id": folder, "name": ""},
			want: ProjectSnapshot{ID: folder, Name: "notes", DefaultName: "notes", Path: folder, Color: "blue"},
		},
		{
			name: "empty color clears the color",
			body: map[string]any{"project_id": folder, "color": ""},
			want: ProjectSnapshot{ID: folder, Name: "notes", DefaultName: "notes", Path: folder},
		},
		{
			name: "absent color keeps the cleared color clear",
			body: map[string]any{"project_id": folder, "name": "Renamed"},
			want: ProjectSnapshot{ID: folder, Name: "Renamed", DefaultName: "notes", Path: folder},
		},
	}
	for _, step := range steps {
		t.Run(step.name, func(t *testing.T) {
			got, err := server.mutateProjectUpdate(mustProjectJSON(t, step.body))
			if err != nil {
				t.Fatalf("update: %v", err)
			}
			if !reflect.DeepEqual(got, step.want) {
				t.Fatalf("updated project = %#v, want %#v", got, step.want)
			}
		})
	}
}

func TestProjectUpdateWorksForDiscoveredProject(t *testing.T) {
	t.Parallel()

	server, store := newProjectTestServer(t)
	repoRoot := resolvedProjectTempDir(t)
	mkProjectFolder(t, filepath.Join(repoRoot, ".git"))
	identity := filepath.Join(repoRoot, ".git")
	// A stored color is enough to discover a repo the tracker has no session for.
	if err := state.NewRepoColorStore(store.Root()).Set(identity, "red"); err != nil {
		t.Fatalf("seed repo color: %v", err)
	}

	got, err := server.mutateProjectUpdate(mustProjectJSON(t, map[string]any{"project_id": identity, "name": "Dots"}))
	if err != nil {
		t.Fatalf("update discovered project: %v", err)
	}
	want := ProjectSnapshot{ID: identity, Name: "Dots", DefaultName: filepath.Base(repoRoot), Path: repoRoot, Color: "red"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("updated project = %#v, want %#v", got, want)
	}
}

func TestProjectUpdateRejectsUnknownProjectAndBadColor(t *testing.T) {
	t.Parallel()

	server, _ := newProjectTestServer(t)
	folder := mkProjectFolder(t, filepath.Join(resolvedProjectTempDir(t), "notes"))
	addProjectFolder(t, server, folder, "", "")

	tests := []struct {
		name    string
		body    map[string]any
		wantErr string
	}{
		{name: "unknown project", body: map[string]any{"project_id": "/nowhere"}, wantErr: "not found"},
		{name: "missing project id", body: map[string]any{"name": "x"}, wantErr: "project_id is required"},
		{name: "invalid color", body: map[string]any{"project_id": folder, "color": "mauve"}, wantErr: "invalid color"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, err := server.mutateProjectUpdate(mustProjectJSON(t, tt.body))
			if err == nil || !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("update error = %v, want one containing %q", err, tt.wantErr)
			}
		})
	}
}

func TestProjectReorderPutsListedProjectsFirstAndKeepsTheRest(t *testing.T) {
	t.Parallel()

	server, _ := newProjectTestServer(t)
	base := resolvedProjectTempDir(t)
	alpha := mkProjectFolder(t, filepath.Join(base, "alpha"))
	beta := mkProjectFolder(t, filepath.Join(base, "beta"))
	gamma := mkProjectFolder(t, filepath.Join(base, "gamma"))
	for _, folder := range []string{alpha, beta, gamma} {
		addProjectFolder(t, server, folder, "", "")
	}
	if ids := projectIDs(t, server); !reflect.DeepEqual(ids, []string{alpha, beta, gamma}) {
		t.Fatalf("unordered projects = %v, want alphabetical", ids)
	}

	got, err := server.mutateProjectReorder(mustProjectJSON(t, map[string]any{"project_ids": []string{gamma, alpha}}))
	if err != nil {
		t.Fatalf("reorder: %v", err)
	}
	want := []string{gamma, alpha, beta}
	if !reflect.DeepEqual(got, map[string][]string{"project_ids": want}) {
		t.Fatalf("reorder response = %#v, want %v", got, want)
	}
	if ids := projectIDs(t, server); !reflect.DeepEqual(ids, want) {
		t.Fatalf("known projects after reorder = %v, want %v", ids, want)
	}
}

func TestProjectReorderRejectsBadListsWithoutSaving(t *testing.T) {
	t.Parallel()

	server, store := newProjectTestServer(t)
	folder := mkProjectFolder(t, filepath.Join(resolvedProjectTempDir(t), "notes"))
	addProjectFolder(t, server, folder, "", "")

	tests := []struct {
		name string
		body map[string]any
	}{
		{name: "no list", body: map[string]any{}},
		{name: "empty list", body: map[string]any{"project_ids": []string{}}},
		{name: "unknown id", body: map[string]any{"project_ids": []string{"/nowhere"}}},
		{name: "duplicate id", body: map[string]any{"project_ids": []string{folder, folder}}},
		{name: "blank id", body: map[string]any{"project_ids": []string{" "}}},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if _, err := server.mutateProjectReorder(mustProjectJSON(t, tt.body)); err == nil {
				t.Fatalf("reorder %v succeeded, want an error", tt.body)
			}
		})
	}
	reg, err := state.NewProjectStore(store.Root()).Load()
	if err != nil {
		t.Fatalf("load registry: %v", err)
	}
	if len(reg.Order) != 0 {
		t.Fatalf("rejected reorders saved order %v", reg.Order)
	}
}

func TestProjectRegistryChangeIsABroadTrackerChange(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	source := &FileChangeSource{stateRoot: root}

	change := source.classify(filepath.Join(root, state.ProjectRegistryFile))
	if !change.BroadTracker || !reflect.DeepEqual(change.Topics, []string{topicTracker}) {
		t.Fatalf("projects.json change = %#v, want a broad tracker change", change)
	}
}
