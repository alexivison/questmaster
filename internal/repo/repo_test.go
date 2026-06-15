package repo

import (
	"os"
	"path/filepath"
	"testing"
)

// mkRepo builds a normal checkout: <root>/.git as a directory.
func mkRepo(t *testing.T, root string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0o755); err != nil {
		t.Fatalf("create .git dir: %v", err)
	}
}

// mkWorktree mirrors `git worktree add`: a main repo with a
// worktrees/<name>/commondir of "../.." and a linked worktree whose .git is a
// file pointing back at that worktrees/<name> dir.
func mkWorktree(t *testing.T, mainRoot, wtRoot, name string) {
	t.Helper()
	mkRepo(t, mainRoot)
	wtMeta := filepath.Join(mainRoot, ".git", "worktrees", name)
	if err := os.MkdirAll(wtMeta, 0o755); err != nil {
		t.Fatalf("create worktree meta: %v", err)
	}
	if err := os.WriteFile(filepath.Join(wtMeta, "commondir"), []byte("../..\n"), 0o644); err != nil {
		t.Fatalf("write commondir: %v", err)
	}
	if err := os.MkdirAll(wtRoot, 0o755); err != nil {
		t.Fatalf("create worktree root: %v", err)
	}
	pointer := "gitdir: " + wtMeta + "\n"
	if err := os.WriteFile(filepath.Join(wtRoot, ".git"), []byte(pointer), 0o644); err != nil {
		t.Fatalf("write worktree .git file: %v", err)
	}
}

func eval(t *testing.T, path string) string {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		t.Fatalf("eval symlinks %q: %v", path, err)
	}
	return resolved
}

func TestResolveNormalRepo(t *testing.T) {
	t.Parallel()

	tmp := t.TempDir()
	root := filepath.Join(tmp, "myrepo")
	mkRepo(t, root)
	wantIdentity := eval(t, filepath.Join(root, ".git"))

	cases := map[string]string{
		"from root":   root,
		"from subdir": filepath.Join(root, "a", "b", "c"),
	}
	for name, path := range cases {
		path := path
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			if err := os.MkdirAll(path, 0o755); err != nil {
				t.Fatalf("mkdir: %v", err)
			}
			got, ok := Resolve(path)
			if !ok {
				t.Fatalf("Resolve(%q) ok = false, want true", path)
			}
			if got.Identity != wantIdentity {
				t.Fatalf("identity = %q, want %q", got.Identity, wantIdentity)
			}
			if got.Name != "myrepo" {
				t.Fatalf("name = %q, want myrepo", got.Name)
			}
		})
	}
}

func TestResolveLinkedWorktreeFoldsOntoMainRepo(t *testing.T) {
	t.Parallel()

	tmp := t.TempDir()
	mainRoot := filepath.Join(tmp, "project")
	wtRoot := filepath.Join(tmp, "project-feature")
	mkWorktree(t, mainRoot, wtRoot, "feature")

	main, ok := Resolve(mainRoot)
	if !ok {
		t.Fatalf("Resolve(main) ok = false")
	}
	wt, ok := Resolve(wtRoot)
	if !ok {
		t.Fatalf("Resolve(worktree) ok = false")
	}

	if wt.Identity != main.Identity {
		t.Fatalf("worktree identity %q != main identity %q", wt.Identity, main.Identity)
	}
	if wt.Name != "project" {
		t.Fatalf("worktree name = %q, want project (main repo name)", wt.Name)
	}
	// Resolving from inside the worktree subtree folds the same way.
	deep := filepath.Join(wtRoot, "src", "pkg")
	if err := os.MkdirAll(deep, 0o755); err != nil {
		t.Fatalf("mkdir worktree subdir: %v", err)
	}
	got, ok := Resolve(deep)
	if !ok || got.Identity != main.Identity {
		t.Fatalf("Resolve(worktree subdir) = %+v ok=%v, want identity %q", got, ok, main.Identity)
	}
}

func TestResolveSymlinkedPathSharesIdentity(t *testing.T) {
	t.Parallel()

	tmp := t.TempDir()
	root := filepath.Join(tmp, "repo")
	mkRepo(t, root)

	link := filepath.Join(tmp, "link")
	if err := os.Symlink(root, link); err != nil {
		t.Skipf("symlinks unsupported: %v", err)
	}

	direct, ok := Resolve(root)
	if !ok {
		t.Fatalf("Resolve(root) ok = false")
	}
	viaLink, ok := Resolve(link)
	if !ok {
		t.Fatalf("Resolve(link) ok = false")
	}
	if viaLink.Identity != direct.Identity {
		t.Fatalf("symlinked path identity %q != direct %q", viaLink.Identity, direct.Identity)
	}
}

func TestResolveNestedReposResolveToNearest(t *testing.T) {
	t.Parallel()

	tmp := t.TempDir()
	outer := filepath.Join(tmp, "outer")
	inner := filepath.Join(outer, "vendor", "inner")
	mkRepo(t, outer)
	mkRepo(t, inner)

	wantInner := eval(t, filepath.Join(inner, ".git"))
	got, ok := Resolve(filepath.Join(inner, "sub"))
	if !ok {
		t.Fatalf("Resolve(nested) ok = false")
	}
	if got.Identity != wantInner {
		t.Fatalf("nested identity = %q, want nearest %q", got.Identity, wantInner)
	}
}

func TestResolveNonGitPathIsNotARepo(t *testing.T) {
	t.Parallel()

	tmp := t.TempDir()
	plain := filepath.Join(tmp, "no-git", "here")
	if err := os.MkdirAll(plain, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if got, ok := Resolve(plain); ok {
		t.Fatalf("Resolve(non-git) ok = true (%+v), want false", got)
	}
}

func TestResolveEmptyPathIsNotARepo(t *testing.T) {
	t.Parallel()

	if _, ok := Resolve(""); ok {
		t.Fatal("Resolve(\"\") ok = true, want false")
	}
	if _, ok := Resolve("   "); ok {
		t.Fatal("Resolve(whitespace) ok = true, want false")
	}
}

func TestCacheMemoizesAndMatchesResolve(t *testing.T) {
	t.Parallel()

	tmp := t.TempDir()
	root := filepath.Join(tmp, "cached")
	mkRepo(t, root)

	c := NewCache()
	first, ok := c.Resolve(root)
	if !ok {
		t.Fatalf("cache Resolve ok = false")
	}
	direct, _ := Resolve(root)
	if first.Identity != direct.Identity {
		t.Fatalf("cache identity %q != direct %q", first.Identity, direct.Identity)
	}

	// A second call returns the memoized value even after .git is removed.
	if err := os.RemoveAll(filepath.Join(root, ".git")); err != nil {
		t.Fatalf("remove .git: %v", err)
	}
	second, ok := c.Resolve(root)
	if !ok || second.Identity != first.Identity {
		t.Fatalf("cache did not memoize: got %+v ok=%v", second, ok)
	}
}
