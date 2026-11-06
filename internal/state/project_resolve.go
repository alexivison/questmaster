package state

import (
	"path/filepath"
	"strings"
	"sync"

	"github.com/alexivison/questmaster/internal/repo"
)

// Project is a folder the tracker, quests and artifacts group by. ID is the
// repo identity for a repo's project, and the folder's symlink-resolved path
// for an added folder that is not a repo's main root. Name is the effective
// display name; DefaultName is the folder name it falls back to.
type Project struct {
	ID          string
	Path        string
	DefaultName string
	Name        string
}

// ProjectResolver maps a path to its project. Repo lookups and symlink
// resolution are memoized per path, so a long-lived resolver costs map reads on
// each tracker rescan. It is safe for concurrent use.
type ProjectResolver struct {
	repos    *repo.Cache
	mu       sync.Mutex
	resolved map[string]string
}

// NewProjectResolver returns a resolver with empty memo tables.
func NewProjectResolver() *ProjectResolver {
	return &ProjectResolver{repos: repo.NewCache(), resolved: make(map[string]string)}
}

// Resolve gives the project a path belongs to:
//  1. the deepest added folder containing the path, when that folder is at or
//     below the path's checkout (a subfolder project inside a checkout);
//  2. otherwise the path's repo, with linked worktrees folded onto their main repo;
//  3. otherwise the deepest added folder containing the path (a plain folder
//     under an added parent).
//
// ok is false when none applies, which is the ungrouped case.
func (r *ProjectResolver) Resolve(reg ProjectRegistry, path string) (Project, bool) {
	if strings.TrimSpace(path) == "" {
		return Project{}, false
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return Project{}, false
	}
	resolved := r.resolvedPath(abs)
	folder, hasFolder := reg.deepestAddedFolder(resolved)
	checkout, inRepo := r.repos.Resolve(resolved)

	switch {
	case hasFolder && inRepo && PathWithin(checkout.Checkout, folder.Path):
		return folder, true
	case inRepo:
		return reg.project(checkout.Identity, checkout.Root), true
	case hasFolder:
		return folder, true
	}
	return Project{}, false
}

// resolvedPath follows symlinks so a path reached through a link (macOS
// /tmp -> /private/tmp) compares equal to the real folder an added project
// stores. A path that does not exist resolves to itself.
func (r *ProjectResolver) resolvedPath(abs string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	if path, ok := r.resolved[abs]; ok {
		return path
	}
	path := abs
	if real, err := filepath.EvalSymlinks(abs); err == nil {
		path = real
	}
	r.resolved[abs] = path
	return path
}

// AddedProjects lists every project that is an added folder, whether or not
// any session, artifact or quest lives in it yet.
func (reg ProjectRegistry) AddedProjects() []Project {
	var projects []Project
	for id, record := range reg.Projects {
		if record.Path != "" {
			projects = append(projects, reg.project(id, record.Path))
		}
	}
	return projects
}

// displayName is the effective name of a project: its override when one is
// set, otherwise defaultName.
func (reg ProjectRegistry) displayName(id, defaultName string) string {
	if name := strings.TrimSpace(reg.Projects[id].Name); name != "" {
		return name
	}
	return defaultName
}

func (reg ProjectRegistry) project(id, path string) Project {
	defaultName := filepath.Base(path)
	return Project{ID: id, Path: path, DefaultName: defaultName, Name: reg.displayName(id, defaultName)}
}

// deepestAddedFolder returns the added folder that contains path and sits
// deepest. Equal depths cannot both contain path unless they are the same
// folder, so the ID breaks the tie only to keep the choice deterministic.
func (reg ProjectRegistry) deepestAddedFolder(path string) (Project, bool) {
	var best Project
	found := false
	for id, record := range reg.Projects {
		if record.Path == "" || !PathWithin(record.Path, path) {
			continue
		}
		candidate := reg.project(id, record.Path)
		if !found || len(candidate.Path) > len(best.Path) || (len(candidate.Path) == len(best.Path) && candidate.ID < best.ID) {
			best, found = candidate, true
		}
	}
	return best, found
}

// PathWithin reports whether p is root or lies beneath it. Both must be
// cleaned absolute paths.
func PathWithin(root, p string) bool {
	rel, err := filepath.Rel(root, p)
	if err != nil || filepath.IsAbs(rel) {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)))
}

// ProjectOrder ranks project IDs in the user's order.
type ProjectOrder map[string]int

// NewProjectOrder ranks ids by position. A repeated ID keeps its first position.
func NewProjectOrder(ids []string) ProjectOrder {
	order := make(ProjectOrder, len(ids))
	for i, id := range ids {
		if _, seen := order[id]; !seen {
			order[id] = i
		}
	}
	return order
}

// Less reports whether project a sorts before project b. Projects in the
// stored order come first, in that order. The rest follow alphabetically by
// display name (case-insensitive), then by ID.
func (o ProjectOrder) Less(aID, aName, bID, bName string) bool {
	aRank, aStored := o[aID]
	bRank, bStored := o[bID]
	if aStored != bStored {
		return aStored
	}
	if aStored {
		return aRank < bRank
	}
	left, right := strings.ToLower(aName), strings.ToLower(bName)
	if left != right {
		return left < right
	}
	return aID < bID
}
