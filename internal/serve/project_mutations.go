//go:build linux || darwin

package serve

import (
	"encoding/json"
	"fmt"
	"strings"

	"github.com/alexivison/questmaster/internal/state"
)

// projectUpdatePayload separates an absent field from an empty one. An absent
// name or color leaves the stored value alone; an empty one clears it.
type projectUpdatePayload struct {
	ProjectID string  `json:"project_id"`
	Name      *string `json:"name"`
	Color     *string `json:"color"`
}

type projectReorderPayload struct {
	ProjectIDs []string `json:"project_ids"`
}

func (s *Server) mutateProjectAdd(payload mutationPayload) (any, error) {
	color, err := mutationDisplayColor(payload.Color)
	if err != nil {
		return nil, err
	}
	id, folder, err := state.ProjectIDForFolder(payload.Path)
	if err != nil {
		return nil, err
	}
	store := s.mutationStore()
	name := strings.TrimSpace(payload.Name)
	if err := state.NewProjectStore(store.Root()).Update(func(reg *state.ProjectRegistry) error {
		reg.SetPath(id, folder)
		if name != "" {
			reg.SetName(id, name)
		}
		return nil
	}); err != nil {
		return nil, err
	}
	if color != "" {
		if err := state.NewRepoColorStore(store.Root()).Set(id, color); err != nil {
			return nil, err
		}
	}
	return s.project(id)
}

func (s *Server) mutateProjectUpdate(raw json.RawMessage) (any, error) {
	var payload projectUpdatePayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, fmt.Errorf("decode project update: %w", err)
	}
	id, err := requiredValue("project_id", payload.ProjectID)
	if err != nil {
		return nil, err
	}
	if _, err := s.project(id); err != nil {
		return nil, err
	}
	color := ""
	if payload.Color != nil {
		if color, err = mutationDisplayColor(*payload.Color); err != nil {
			return nil, err
		}
	}

	store := s.mutationStore()
	if payload.Name != nil {
		name := *payload.Name
		if err := state.NewProjectStore(store.Root()).Update(func(reg *state.ProjectRegistry) error {
			reg.SetName(id, name)
			return nil
		}); err != nil {
			return nil, err
		}
	}
	if payload.Color != nil {
		if err := state.NewRepoColorStore(store.Root()).Set(id, color); err != nil {
			return nil, err
		}
	}
	return s.project(id)
}

func (s *Server) mutateProjectReorder(raw json.RawMessage) (any, error) {
	var payload projectReorderPayload
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, fmt.Errorf("decode project reorder: %w", err)
	}
	if len(payload.ProjectIDs) == 0 {
		return nil, fmt.Errorf("project_ids is required")
	}
	current, err := s.knownProjects()
	if err != nil {
		return nil, err
	}
	ordered, err := reorderProjects(current, payload.ProjectIDs)
	if err != nil {
		return nil, err
	}
	if err := state.NewProjectStore(s.mutationStore().Root()).Update(func(reg *state.ProjectRegistry) error {
		reg.Order = ordered
		return nil
	}); err != nil {
		return nil, err
	}
	return map[string][]string{"project_ids": ordered}, nil
}

// reorderProjects puts the listed projects first, in the listed order, and
// keeps every other project after them in its current order. Each listed ID
// must name a known project, and none may repeat.
func reorderProjects(current []ProjectSnapshot, listed []string) ([]string, error) {
	known := make(map[string]bool, len(current))
	for _, project := range current {
		known[project.ID] = true
	}
	seen := make(map[string]bool, len(listed))
	ordered := make([]string, 0, len(current))
	for _, raw := range listed {
		id := strings.TrimSpace(raw)
		if id == "" {
			return nil, fmt.Errorf("project_ids must not contain an empty id")
		}
		if !known[id] {
			return nil, fmt.Errorf("project %q not found", id)
		}
		if seen[id] {
			return nil, fmt.Errorf("project %q is listed more than once", id)
		}
		seen[id] = true
		ordered = append(ordered, id)
	}
	for _, project := range current {
		if !seen[project.ID] {
			ordered = append(ordered, project.ID)
		}
	}
	return ordered, nil
}

// project returns one project's current snapshot, or an error when no project
// has that ID.
func (s *Server) project(id string) (ProjectSnapshot, error) {
	projects, err := s.knownProjects()
	if err != nil {
		return ProjectSnapshot{}, err
	}
	for _, project := range projects {
		if project.ID == id {
			return project, nil
		}
	}
	return ProjectSnapshot{}, fmt.Errorf("project %q not found", id)
}

// knownProjects lists the projects the tracker shows, in the user's order.
func (s *Server) knownProjects() ([]ProjectSnapshot, error) {
	store := s.mutationStore()
	artifacts, err := state.LoadArtifactsGlobal(store.Root())
	if err != nil {
		return nil, fmt.Errorf("load artifacts: %w", err)
	}
	quests, err := state.LoadQuestsAt(store.Root())
	if err != nil {
		return nil, fmt.Errorf("load quests: %w", err)
	}
	return buildProjectSnapshots(store, state.NewProjectResolver(), artifacts, quests)
}
