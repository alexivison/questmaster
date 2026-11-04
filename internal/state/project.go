//go:build linux || darwin

package state

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/alexivison/questmaster/internal/repo"
)

// ProjectRegistryFile is the basename of the project registry under the state root.
const ProjectRegistryFile = "projects.json"

// ProjectRegistry is the user's project list: the order they arranged it in,
// the folders they added, and display-name overrides. Project colors stay in
// repo-colors.json, keyed by the same project ID.
type ProjectRegistry struct {
	Order    []string                 `json:"order,omitempty"`
	Projects map[string]ProjectRecord `json:"projects,omitempty"`
}

// ProjectRecord is one project's stored settings. Path is set only for an
// added folder; Name only when the user overrides the folder name.
type ProjectRecord struct {
	Path string `json:"path,omitempty"`
	Name string `json:"name,omitempty"`
}

// ProjectStore persists the project registry in <root>/projects.json. Writes
// use the same atomic-rename and flock discipline as RepoColorStore.
type ProjectStore struct {
	path string
}

// NewProjectStore returns a store backed by <root>/projects.json.
func NewProjectStore(root string) *ProjectStore {
	return &ProjectStore{path: filepath.Join(root, ProjectRegistryFile)}
}

// Load reads the registry. A missing file is an empty registry.
func (s *ProjectStore) Load() (ProjectRegistry, error) {
	data, err := os.ReadFile(s.path)
	if err != nil {
		if os.IsNotExist(err) {
			return ProjectRegistry{}, nil
		}
		return ProjectRegistry{}, fmt.Errorf("read projects: %w", err)
	}
	var reg ProjectRegistry
	if err := json.Unmarshal(data, &reg); err != nil {
		return ProjectRegistry{}, fmt.Errorf("parse projects: %w", err)
	}
	return reg, nil
}

// Update applies fn to the registry under an exclusive lock and writes the
// result. A registry that fails to parse is an error rather than an empty
// base, so an update never replaces the user's stored list.
func (s *ProjectStore) Update(fn func(*ProjectRegistry) error) error {
	if err := EnsurePrivateStateRoot(filepath.Dir(s.path)); err != nil {
		return fmt.Errorf("create state root: %w", err)
	}
	return withFileLock(s.path+".lock", func() error {
		reg, err := s.Load()
		if err != nil {
			return err
		}
		if err := fn(&reg); err != nil {
			return err
		}
		return s.write(reg)
	})
}

func (s *ProjectStore) write(reg ProjectRegistry) error {
	data, err := json.MarshalIndent(reg, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal projects: %w", err)
	}
	data = append(data, '\n')

	tmp := s.path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write temp projects: %w", err)
	}
	if err := os.Rename(tmp, s.path); err != nil {
		os.Remove(tmp) //nolint:errcheck
		return fmt.Errorf("rename projects: %w", err)
	}
	return nil
}

// SetName stores a display-name override for id. An empty name removes it, so
// the project shows its folder name again.
func (reg *ProjectRegistry) SetName(id, name string) {
	record := reg.Projects[id]
	record.Name = strings.TrimSpace(name)
	reg.setRecord(id, record)
}

// SetPath records id as an added folder at path.
func (reg *ProjectRegistry) SetPath(id, path string) {
	record := reg.Projects[id]
	record.Path = path
	reg.setRecord(id, record)
}

// setRecord keeps the map free of empty entries, so a cleared override leaves
// nothing behind.
func (reg *ProjectRegistry) setRecord(id string, record ProjectRecord) {
	if record == (ProjectRecord{}) {
		delete(reg.Projects, id)
		return
	}
	if reg.Projects == nil {
		reg.Projects = make(map[string]ProjectRecord)
	}
	reg.Projects[id] = record
}

// ProjectIDForFolder names the project an added folder becomes. The path must
// be absolute (after ~ expansion) and an existing directory. A folder that is
// exactly a repo's main root is that repo's project, so it is keyed by repo
// identity. Any other folder is its own project, keyed by its symlink-resolved
// path. It returns the project ID and the resolved folder path.
func ProjectIDForFolder(path string) (id, folder string, err error) {
	path = strings.TrimSpace(path)
	if path == "" {
		return "", "", fmt.Errorf("project path is required")
	}
	expanded := ExpandHome(path)
	if !filepath.IsAbs(expanded) {
		return "", "", fmt.Errorf("project path must be absolute: %s", path)
	}
	info, err := os.Stat(expanded)
	if err != nil {
		return "", "", fmt.Errorf("project path %s: %w", path, err)
	}
	if !info.IsDir() {
		return "", "", fmt.Errorf("project path is not a directory: %s", path)
	}
	folder, err = filepath.EvalSymlinks(expanded)
	if err != nil {
		return "", "", fmt.Errorf("resolve project path %s: %w", path, err)
	}
	if r, ok := repo.Resolve(folder); ok && r.Root == folder {
		return r.Identity, folder, nil
	}
	return folder, folder, nil
}

// ProjectIDAt returns the project ID a path belongs to under stateRoot, or ""
// when it is ungrouped. A registry that cannot be read leaves no added folders
// or names, so the path still resolves to its repo.
func ProjectIDAt(stateRoot, path string) string {
	reg, _ := NewProjectStore(stateRoot).Load()
	project, ok := NewProjectResolver().Resolve(reg, path)
	if !ok {
		return ""
	}
	return project.ID
}
