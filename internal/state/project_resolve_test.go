package state

import (
	"os"
	"path/filepath"
	"testing"
)

// projectFixture lays out a home folder that holds two checkouts, a worktree
// of the second checkout nested under the first, and a plain folder.
type projectFixture struct {
	home       string
	appRepo    string // checkout
	appRepoID  string
	toolRepo   string // checkout
	toolRepoID string
	worktree   string // linked worktree of the tool repo, nested under the app repo
	scratch    string // plain folder, no git
}

func newProjectFixture(t *testing.T) projectFixture {
	t.Helper()
	base := resolvedTempDir(t)
	fx := projectFixture{
		home:     filepath.Join(base, "workspace"),
		appRepo:  filepath.Join(base, "workspace", "example-app"),
		toolRepo: filepath.Join(base, "workspace", "example-tool"),
		worktree: filepath.Join(base, "workspace", "example-app", ".worktrees", "branch", "qm-branch"),
		scratch:  filepath.Join(base, "workspace", "scratch"),
	}
	fx.appRepoID = filepath.Join(fx.appRepo, ".git")
	fx.toolRepoID = filepath.Join(fx.toolRepo, ".git")
	mustMkdir(t, filepath.Join(fx.appRepo, ".git"))
	mustMkdir(t, filepath.Join(fx.toolRepo, ".git"))
	mustMkdir(t, fx.scratch)
	mkLinkedWorktree(t, fx.toolRepo, fx.worktree)
	return fx
}

// resolvedTempDir returns a temp dir with symlinks resolved, so expected paths
// match what the resolver reports on macOS, where /var is a link to /private/var.
func resolvedTempDir(t *testing.T) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatalf("resolve temp dir: %v", err)
	}
	return resolved
}

func mustMkdir(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(path, 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
}

// mkLinkedWorktree mirrors `git worktree add`: the main repo keeps
// worktrees/<name>/commondir, and the worktree's .git file points back at it.
func mkLinkedWorktree(t *testing.T, mainRoot, wtRoot string) {
	t.Helper()
	meta := filepath.Join(mainRoot, ".git", "worktrees", filepath.Base(wtRoot))
	mustMkdir(t, meta)
	if err := os.WriteFile(filepath.Join(meta, "commondir"), []byte("../..\n"), 0o644); err != nil {
		t.Fatalf("write commondir: %v", err)
	}
	mustMkdir(t, wtRoot)
	if err := os.WriteFile(filepath.Join(wtRoot, ".git"), []byte("gitdir: "+meta+"\n"), 0o644); err != nil {
		t.Fatalf("write worktree .git: %v", err)
	}
}

func TestProjectResolveCases(t *testing.T) {
	t.Parallel()

	fx := newProjectFixture(t)
	registry := func(added ...string) ProjectRegistry {
		reg := ProjectRegistry{Projects: map[string]ProjectRecord{}}
		for _, path := range added {
			reg.Projects[path] = ProjectRecord{Path: path}
		}
		return reg
	}

	tests := []struct {
		name     string
		reg      ProjectRegistry
		path     string
		wantOK   bool
		wantID   string
		wantName string
	}{
		{
			name:     "checkout without added folders is its repo",
			reg:      registry(),
			path:     fx.appRepo,
			wantOK:   true,
			wantID:   fx.appRepoID,
			wantName: "example-app",
		},
		{
			name:   "non-repo cwd with nothing added is ungrouped",
			reg:    registry(),
			path:   fx.scratch,
			wantOK: false,
		},
		{
			name:     "worktree folds onto its main repo",
			reg:      registry(),
			path:     fx.worktree,
			wantOK:   true,
			wantID:   fx.toolRepoID,
			wantName: "example-tool",
		},
		{
			name:     "added parent above checkouts leaves repo cwds on their repo",
			reg:      registry(fx.home),
			path:     fx.appRepo,
			wantOK:   true,
			wantID:   fx.appRepoID,
			wantName: "example-app",
		},
		{
			name:     "worktree under another repo stays in its own repo, not the added parent",
			reg:      registry(fx.home),
			path:     fx.worktree,
			wantOK:   true,
			wantID:   fx.toolRepoID,
			wantName: "example-tool",
		},
		{
			name:     "plain folder under an added parent is that parent",
			reg:      registry(fx.home),
			path:     fx.scratch,
			wantOK:   true,
			wantID:   fx.home,
			wantName: "workspace",
		},
		{
			name:     "added subfolder inside a checkout wins over the repo",
			reg:      registry(filepath.Join(fx.appRepo, "notes")),
			path:     filepath.Join(fx.appRepo, "notes", "day-1"),
			wantOK:   true,
			wantID:   filepath.Join(fx.appRepo, "notes"),
			wantName: "notes",
		},
		{
			name:     "checkout outside an added subfolder stays on the repo",
			reg:      registry(filepath.Join(fx.appRepo, "notes")),
			path:     filepath.Join(fx.appRepo, "src"),
			wantOK:   true,
			wantID:   fx.appRepoID,
			wantName: "example-app",
		},
		{
			name:     "added folder equal to a repo root is that repo's project",
			reg:      ProjectRegistry{Projects: map[string]ProjectRecord{fx.appRepoID: {Path: fx.appRepo}}},
			path:     fx.appRepo,
			wantOK:   true,
			wantID:   fx.appRepoID,
			wantName: "example-app",
		},
		{
			name:     "display-name override replaces the folder name",
			reg:      ProjectRegistry{Projects: map[string]ProjectRecord{fx.appRepoID: {Name: "Dots"}}},
			path:     fx.appRepo,
			wantOK:   true,
			wantID:   fx.appRepoID,
			wantName: "Dots",
		},
	}

	resolver := NewProjectResolver()
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got, ok := resolver.Resolve(tt.reg, tt.path)
			if ok != tt.wantOK {
				t.Fatalf("ok = %v, want %v (project %#v)", ok, tt.wantOK, got)
			}
			if !ok {
				return
			}
			if got.ID != tt.wantID || got.Name != tt.wantName {
				t.Fatalf("project = {ID: %q, Name: %q}, want {ID: %q, Name: %q}", got.ID, got.Name, tt.wantID, tt.wantName)
			}
		})
	}
}

func TestProjectResolveFollowsSymlinkedPaths(t *testing.T) {
	t.Parallel()

	fx := newProjectFixture(t)
	alias := filepath.Join(filepath.Dir(fx.home), "alias")
	if err := os.Symlink(fx.home, alias); err != nil {
		t.Fatalf("symlink: %v", err)
	}
	reg := ProjectRegistry{Projects: map[string]ProjectRecord{fx.home: {Path: fx.home}}}

	got, ok := NewProjectResolver().Resolve(reg, filepath.Join(alias, "scratch"))
	if !ok || got.ID != fx.home {
		t.Fatalf("resolve through symlink = %#v, %v; want added folder %s", got, ok, fx.home)
	}
}

func TestProjectResolveFollowsAddedFolderRegisteredAsItsOwnPath(t *testing.T) {
	t.Parallel()

	fx := newProjectFixture(t)
	outer := filepath.Join(fx.home, "notes")
	inner := filepath.Join(outer, "deep")
	mustMkdir(t, inner)
	reg := ProjectRegistry{Projects: map[string]ProjectRecord{
		fx.home: {Path: fx.home},
		outer:   {Path: outer, Name: "Notes"},
	}}

	got, ok := NewProjectResolver().Resolve(reg, filepath.Join(inner, "today"))
	if !ok || got.ID != outer || got.Name != "Notes" || got.DefaultName != "notes" {
		t.Fatalf("deepest added folder = %#v, %v; want notes with its override", got, ok)
	}
}

func TestProjectOrderLess(t *testing.T) {
	t.Parallel()

	order := NewProjectOrder([]string{"/p/gamma", "/p/alpha", "/p/gamma"})
	tests := []struct {
		name       string
		aID, aName string
		bID, bName string
		want       bool
	}{
		{"stored project precedes an unstored one", "/p/alpha", "alpha", "/p/beta", "aardvark", true},
		{"unstored project does not precede a stored one", "/p/beta", "aardvark", "/p/alpha", "alpha", false},
		{"stored projects keep stored order", "/p/gamma", "gamma", "/p/alpha", "alpha", true},
		{"stored projects reversed by stored order", "/p/alpha", "alpha", "/p/gamma", "gamma", false},
		{"unstored projects sort by name ignoring case", "/p/b", "Bravo", "/p/c", "charlie", true},
		{"equal names break ties by ID", "/p/a", "same", "/p/b", "same", true},
		{"identical projects are not less", "/p/a", "same", "/p/a", "same", false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			if got := order.Less(tt.aID, tt.aName, tt.bID, tt.bName); got != tt.want {
				t.Fatalf("Less(%q, %q, %q, %q) = %v, want %v", tt.aID, tt.aName, tt.bID, tt.bName, got, tt.want)
			}
		})
	}
}

func TestProjectRegistryDisplayNameFallsBackWhenOverrideIsBlank(t *testing.T) {
	t.Parallel()

	reg := ProjectRegistry{Projects: map[string]ProjectRecord{"/p/a": {Name: "   "}}}
	if got := reg.displayName("/p/a", "a"); got != "a" {
		t.Fatalf("DisplayName = %q, want the folder name", got)
	}
}
