package quest

import "sort"

// UnsortedProject is the trailing section label for quests with no project
// (e.g. quests authored before project stamping, or outside any git repo).
const UnsortedProject = "Unsorted"

// ProjectGroup is one project section of the quest log: a project name (or
// UnsortedProject) and its quests, ordered by status then id.
type ProjectGroup struct {
	Project string
	Quests  []Quest
}

// GroupByProject sorts quests into project sections — alphabetical, with the
// project-less "Unsorted" section last — and within each section by status
// (active → wip → done) then id. The board and `quest ls` share it so both
// surfaces present the log identically.
func GroupByProject(quests []Quest) []ProjectGroup {
	sorted := append([]Quest(nil), quests...)
	sort.SliceStable(sorted, func(i, j int) bool {
		pi, pj := projectOf(sorted[i]), projectOf(sorted[j])
		if pi != pj {
			return lessProject(pi, pj)
		}
		if ri, rj := statusRank(sorted[i].Status), statusRank(sorted[j].Status); ri != rj {
			return ri < rj
		}
		return sorted[i].ID < sorted[j].ID
	})

	var groups []ProjectGroup
	for _, q := range sorted {
		p := projectOf(q)
		if n := len(groups); n > 0 && groups[n-1].Project == p {
			groups[n-1].Quests = append(groups[n-1].Quests, q)
			continue
		}
		groups = append(groups, ProjectGroup{Project: p, Quests: []Quest{q}})
	}
	return groups
}

// projectOf is a quest's section: its Project, or UnsortedProject when unset.
func projectOf(q Quest) string {
	if q.Project == "" {
		return UnsortedProject
	}
	return q.Project
}

// lessProject orders project sections alphabetically with Unsorted always last.
func lessProject(a, b string) bool {
	switch {
	case a == b:
		return false
	case a == UnsortedProject:
		return false
	case b == UnsortedProject:
		return true
	default:
		return a < b
	}
}

// statusRank orders rows within a project section: active, then wip, then done.
func statusRank(s Status) int {
	switch s {
	case StatusActive:
		return 0
	case StatusWIP:
		return 1
	default: // done
		return 2
	}
}
