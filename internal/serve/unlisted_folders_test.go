//go:build linux || darwin

package serve

import (
	"fmt"
	"path/filepath"
	"reflect"
	"testing"

	"github.com/alexivison/questmaster/internal/state"
)

// unlistedFixture is a temp root holding the state root at root/state. Tests
// create folders and sessions under root; they set QUESTMASTER_STATE_ROOT, so
// they cannot run in parallel.
type unlistedFixture struct {
	root  string
	store *state.Store
}

func newUnlistedFixture(t *testing.T) unlistedFixture {
	t.Helper()
	root := resolvedProjectTempDir(t)
	stateRoot := mkProjectFolder(t, filepath.Join(root, "state"))
	t.Setenv("QUESTMASTER_STATE_ROOT", stateRoot)
	return unlistedFixture{root: root, store: state.OpenStore(stateRoot)}
}

func (fx unlistedFixture) path(rel string) string {
	return filepath.Join(fx.root, rel)
}

func (fx unlistedFixture) server() *Server {
	return &Server{Snapshotter: &Snapshotter{store: fx.store}}
}

// addSession records a session whose cwd is cwd, named by its position so
// each call creates a new manifest.
func (fx unlistedFixture) addSession(t *testing.T, index int, cwd string) {
	t.Helper()
	if err := fx.store.Create(state.Manifest{TmuxServer: "dev_previous", SessionID: fmt.Sprintf("qm-s%d", index), Cwd: cwd}); err != nil {
		t.Fatalf("create session %d: %v", index, err)
	}
}

// build runs the same pass the tracker payload uses.
func (fx unlistedFixture) build(t *testing.T) []UnlistedFolderSnapshot {
	t.Helper()
	_, unlisted, err := buildProjectSnapshots(fx.store, state.NewProjectResolver(), nil, nil)
	if err != nil {
		t.Fatalf("build project snapshots: %v", err)
	}
	return unlisted
}

func TestUnlistedFolderSnapshots(t *testing.T) {
	type wantFolder struct {
		rel   string
		count int
	}
	cases := []struct {
		name     string
		folders  []string     // created under the root; anything else is missing
		repos    []string     // folders made into git checkouts
		projects []string     // folders added as projects
		sessions []string     // one session per entry, cwd relative to the root
		want     []wantFolder // expected unlisted folders, sorted by path
	}{
		{
			name:     "a folder added as a project is excluded",
			folders:  []string{"app"},
			projects: []string{"app"},
			sessions: []string{"app"},
		},
		{
			name:     "a subfolder of an added project is excluded",
			folders:  []string{"app/src"},
			projects: []string{"app"},
			sessions: []string{"app/src"},
		},
		{
			name:     "a git checkout and its subfolders are excluded",
			folders:  []string{"app/src"},
			repos:    []string{"app"},
			sessions: []string{"app", "app/src"},
		},
		{
			name:     "a folder that no longer exists is excluded",
			sessions: []string{"gone"},
		},
		{
			name:     "the state root and folders under it are excluded",
			folders:  []string{"state/artifacts/plan"},
			sessions: []string{"state", "state/artifacts/plan"},
		},
		{
			name:     "a plain folder is listed with its session count",
			folders:  []string{"scratch"},
			sessions: []string{"scratch", "scratch"},
			want:     []wantFolder{{rel: "scratch", count: 2}},
		},
		{
			name:     "each cwd is counted exactly, not rolled up to a parent",
			folders:  []string{"scratch", "scratch/child"},
			sessions: []string{"scratch", "scratch/child", "scratch/child"},
			want:     []wantFolder{{rel: "scratch", count: 1}, {rel: "scratch/child", count: 2}},
		},
		{
			name:     "listed folders are sorted by path, not by session order",
			folders:  []string{"zeta", "alpha", "mid"},
			sessions: []string{"zeta", "mid", "alpha"},
			want:     []wantFolder{{rel: "alpha", count: 1}, {rel: "mid", count: 1}, {rel: "zeta", count: 1}},
		},
		{
			name:     "a sibling of an added project stays listed",
			folders:  []string{"app", "other"},
			projects: []string{"app"},
			sessions: []string{"app", "other"},
			want:     []wantFolder{{rel: "other", count: 1}},
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			fx := newUnlistedFixture(t)
			for _, rel := range tc.folders {
				mkProjectFolder(t, fx.path(rel))
			}
			for _, rel := range tc.repos {
				mkProjectFolder(t, filepath.Join(fx.path(rel), ".git"))
			}
			for _, rel := range tc.projects {
				addProjectFolder(t, fx.server(), fx.path(rel), "", "")
			}
			for i, rel := range tc.sessions {
				fx.addSession(t, i, fx.path(rel))
			}

			var want []UnlistedFolderSnapshot
			for _, folder := range tc.want {
				want = append(want, UnlistedFolderSnapshot{Path: fx.path(folder.rel), SessionCount: folder.count})
			}
			if got := fx.build(t); !reflect.DeepEqual(got, want) {
				t.Fatalf("unlisted folders = %#v, want %#v", got, want)
			}
		})
	}
}

// Pseudo buckets and relative cwds name no folder, so they never list.
func TestUnlistedFoldersSkipPseudoAndRelativeCwds(t *testing.T) {
	fx := newUnlistedFixture(t)
	for i, cwd := range []string{"", "ungrouped", "_misc", "relative/dir"} {
		fx.addSession(t, i, cwd)
	}

	if got := fx.build(t); len(got) != 0 {
		t.Fatalf("unlisted folders = %#v, want none", got)
	}
}

// Adding a listed folder as a project takes it off the list on the next
// snapshot, and it joins the projects.
func TestAddingAnUnlistedFolderRemovesItFromTheList(t *testing.T) {
	fx := newUnlistedFixture(t)
	scratch := mkProjectFolder(t, fx.path("scratch"))
	fx.addSession(t, 0, scratch)
	if got := fx.build(t); len(got) != 1 {
		t.Fatalf("before add: unlisted folders = %#v, want scratch", got)
	}

	addProjectFolder(t, fx.server(), scratch, "", "")

	projects, unlisted, err := buildProjectSnapshots(fx.store, state.NewProjectResolver(), nil, nil)
	if err != nil {
		t.Fatalf("build project snapshots: %v", err)
	}
	if len(unlisted) != 0 {
		t.Fatalf("after add: unlisted folders = %#v, want none", unlisted)
	}
	if len(projects) != 1 || projects[0].Path != scratch {
		t.Fatalf("after add: projects = %#v, want the scratch folder", projects)
	}
}
