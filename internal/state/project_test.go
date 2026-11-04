//go:build linux || darwin

package state

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestProjectStoreRoundTripsRegistry(t *testing.T) {
	t.Parallel()

	store := NewProjectStore(t.TempDir())
	if err := store.Update(func(reg *ProjectRegistry) error {
		reg.Order = []string{"/p/b", "/p/a"}
		reg.SetPath("/p/a", "/p/a")
		reg.SetName("/p/b", "Bee")
		return nil
	}); err != nil {
		t.Fatalf("update: %v", err)
	}

	reg, err := store.Load()
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if want := []string{"/p/b", "/p/a"}; !reflect.DeepEqual(reg.Order, want) {
		t.Fatalf("order = %v, want %v", reg.Order, want)
	}
	if want := (ProjectRecord{Path: "/p/a"}); reg.Projects["/p/a"] != want {
		t.Fatalf("record for /p/a = %#v, want %#v", reg.Projects["/p/a"], want)
	}
	if want := (ProjectRecord{Name: "Bee"}); reg.Projects["/p/b"] != want {
		t.Fatalf("record for /p/b = %#v, want %#v", reg.Projects["/p/b"], want)
	}
}

func TestProjectStoreMissingFileIsEmptyRegistry(t *testing.T) {
	t.Parallel()

	reg, err := NewProjectStore(t.TempDir()).Load()
	if err != nil {
		t.Fatalf("load missing registry: %v", err)
	}
	if len(reg.Order) != 0 || len(reg.Projects) != 0 {
		t.Fatalf("registry = %#v, want empty", reg)
	}
}

func TestProjectStoreUpdateLeavesCorruptRegistryUntouched(t *testing.T) {
	t.Parallel()

	root := t.TempDir()
	path := filepath.Join(root, ProjectRegistryFile)
	corrupt := []byte("{not json")
	if err := os.WriteFile(path, corrupt, 0o644); err != nil {
		t.Fatalf("write corrupt registry: %v", err)
	}

	err := NewProjectStore(root).Update(func(reg *ProjectRegistry) error {
		reg.Order = []string{"/p/a"}
		return nil
	})
	if err == nil {
		t.Fatal("update over a corrupt registry succeeded, want an error")
	}
	got, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatalf("read registry: %v", readErr)
	}
	if string(got) != string(corrupt) {
		t.Fatalf("corrupt registry was overwritten with %q", got)
	}
}

func TestProjectRegistryEmptyNameClearsOverrideAndKeepsPath(t *testing.T) {
	t.Parallel()

	reg := ProjectRegistry{}
	reg.SetPath("/p/a", "/p/a")
	reg.SetName("/p/a", "Alpha")
	reg.SetName("/p/a", "   ")
	if want := (ProjectRecord{Path: "/p/a"}); reg.Projects["/p/a"] != want {
		t.Fatalf("record = %#v, want %#v", reg.Projects["/p/a"], want)
	}

	reg.SetName("/p/b", "Bee")
	reg.SetName("/p/b", "")
	if _, ok := reg.Projects["/p/b"]; ok {
		t.Fatalf("cleared override left an entry behind: %#v", reg.Projects["/p/b"])
	}
}

func TestProjectIDForFolder(t *testing.T) {
	t.Parallel()

	fx := newProjectFixture(t)
	notes := filepath.Join(fx.appRepo, "notes")
	mustMkdir(t, notes)
	file := filepath.Join(fx.scratch, "readme.txt")
	if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}
	alias := filepath.Join(filepath.Dir(fx.home), "app-link")
	if err := os.Symlink(fx.appRepo, alias); err != nil {
		t.Fatalf("symlink: %v", err)
	}

	tests := []struct {
		name       string
		path       string
		wantID     string
		wantFolder string
		wantErr    bool
	}{
		{name: "checkout root is its repo", path: fx.appRepo, wantID: fx.appRepoID, wantFolder: fx.appRepo},
		{name: "symlink to a checkout root is its repo", path: alias, wantID: fx.appRepoID, wantFolder: fx.appRepo},
		{name: "subfolder of a checkout is its own folder project", path: notes, wantID: notes, wantFolder: notes},
		{name: "linked worktree root is its own folder project", path: fx.worktree, wantID: fx.worktree, wantFolder: fx.worktree},
		{name: "plain folder is its own folder project", path: fx.scratch, wantID: fx.scratch, wantFolder: fx.scratch},
		{name: "relative path is rejected", path: "Code/scratch", wantErr: true},
		{name: "empty path is rejected", path: "  ", wantErr: true},
		{name: "missing path is rejected", path: filepath.Join(fx.home, "missing"), wantErr: true},
		{name: "file is rejected", path: file, wantErr: true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			id, folder, err := ProjectIDForFolder(tt.path)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("ProjectIDForFolder(%q) = %q, %q, want an error", tt.path, id, folder)
				}
				return
			}
			if err != nil {
				t.Fatalf("ProjectIDForFolder(%q): %v", tt.path, err)
			}
			if id != tt.wantID || folder != tt.wantFolder {
				t.Fatalf("ProjectIDForFolder(%q) = %q, %q; want %q, %q", tt.path, id, folder, tt.wantID, tt.wantFolder)
			}
		})
	}
}

func TestProjectIDAtUsesTheStoredRegistry(t *testing.T) {
	t.Parallel()

	fx := newProjectFixture(t)
	root := t.TempDir()
	if got := ProjectIDAt(root, fx.scratch); got != "" {
		t.Fatalf("ungrouped scratch = %q, want empty", got)
	}
	if err := NewProjectStore(root).Update(func(reg *ProjectRegistry) error {
		reg.SetPath(fx.home, fx.home)
		return nil
	}); err != nil {
		t.Fatalf("add home: %v", err)
	}
	if got := ProjectIDAt(root, fx.scratch); got != fx.home {
		t.Fatalf("scratch under added home = %q, want %q", got, fx.home)
	}
	if got := ProjectIDAt(root, fx.worktree); got != fx.toolRepoID {
		t.Fatalf("worktree under added home = %q, want its repo %q", got, fx.toolRepoID)
	}
}
