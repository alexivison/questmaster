// Package repo resolves a filesystem path to its canonical parent git
// repository. It reads .git purely in Go — it never shells out to git and
// never forks a process — so it is safe on the tracker's render/rescan path.
//
// Linked worktrees fold onto their main repository: every worktree of a repo
// shares one stable identity (the resolved common git dir), so they group
// together. The package has no dependency on the TUI or picker, so a later
// machine-wide repo-discovery feature can reuse it unchanged.
package repo

import (
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// Repo is a resolved git repository.
type Repo struct {
	// Identity is the canonical common git dir, symlink-resolved and cleaned.
	// All worktrees of the same repository share it, so it is the grouping key.
	Identity string
	// Root is the main worktree root (the repo's top-level working directory).
	Root string
	// Name is the display name: the base name of Root.
	Name string
}

// gitPointerPrefix marks a linked worktree's .git file ("gitdir: <path>").
const gitPointerPrefix = "gitdir:"

// Resolve walks up from path looking for a .git entry and returns the
// canonical parent repository. A .git directory is a normal checkout; a .git
// file points at a linked worktree, which is folded onto its main repo via
// the worktree's commondir. ok is false for a path outside any git repo or
// for any read error (the caller treats that as "not a repo" / ungrouped).
func Resolve(path string) (Repo, bool) {
	if strings.TrimSpace(path) == "" {
		return Repo{}, false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return Repo{}, false
	}

	dir := filepath.Clean(abs)
	for {
		gitPath := filepath.Join(dir, ".git")
		if info, statErr := os.Stat(gitPath); statErr == nil {
			commonGitDir, ok := commonGitDir(gitPath, info.IsDir())
			if !ok {
				return Repo{}, false
			}
			return build(commonGitDir), true
		}

		parent := filepath.Dir(dir)
		if parent == dir {
			return Repo{}, false
		}
		dir = parent
	}
}

// commonGitDir returns the main repository's git dir for a .git entry. For a
// .git directory that is the directory itself. For a .git file (a linked
// worktree) it follows the gitdir pointer, then the worktree's commondir, to
// reach the main repo's git dir — this is what folds worktrees under their
// parent.
func commonGitDir(gitPath string, isDir bool) (string, bool) {
	if isDir {
		return gitPath, true
	}

	data, err := os.ReadFile(gitPath)
	if err != nil {
		return "", false
	}
	line := strings.TrimSpace(string(data))
	if !strings.HasPrefix(line, gitPointerPrefix) {
		return "", false
	}

	gitDir := strings.TrimSpace(strings.TrimPrefix(line, gitPointerPrefix))
	if !filepath.IsAbs(gitDir) {
		gitDir = filepath.Join(filepath.Dir(gitPath), gitDir)
	}
	gitDir = filepath.Clean(gitDir)

	// commondir points (usually with "../..") from worktrees/<name> back to
	// the main git dir. Absent it, the gitdir itself is the common dir.
	common, err := os.ReadFile(filepath.Join(gitDir, "commondir"))
	if err != nil {
		return gitDir, true
	}
	rel := strings.TrimSpace(string(common))
	if rel == "" {
		return gitDir, true
	}
	if !filepath.IsAbs(rel) {
		rel = filepath.Join(gitDir, rel)
	}
	return filepath.Clean(rel), true
}

// build turns a common git dir into a Repo, resolving symlinks so that paths
// reaching the same repo through different links (e.g. macOS /tmp ->
// /private/tmp) share one identity.
func build(commonGitDir string) Repo {
	identity := commonGitDir
	if resolved, err := filepath.EvalSymlinks(commonGitDir); err == nil {
		identity = resolved
	}
	identity = filepath.Clean(identity)
	root := filepath.Dir(identity)
	return Repo{Identity: identity, Root: root, Name: filepath.Base(root)}
}

// Cache memoizes Resolve per absolute path. A session's cwd does not change
// repos within a run, so the tracker keeps one Cache across refresh ticks and
// avoids re-reading .git on every rescan. It is safe for concurrent use.
type Cache struct {
	mu sync.Mutex
	m  map[string]entry
}

type entry struct {
	repo Repo
	ok   bool
}

// NewCache returns an empty resolution cache.
func NewCache() *Cache {
	return &Cache{m: make(map[string]entry)}
}

// Resolve returns the cached resolution for path, computing it on first use.
func (c *Cache) Resolve(path string) (Repo, bool) {
	if strings.TrimSpace(path) == "" {
		return Repo{}, false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return Repo{}, false
	}

	c.mu.Lock()
	defer c.mu.Unlock()
	if e, ok := c.m[abs]; ok {
		return e.repo, e.ok
	}
	r, ok := Resolve(abs)
	c.m[abs] = entry{repo: r, ok: ok}
	return r, ok
}
