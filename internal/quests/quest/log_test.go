package quest

import (
	"reflect"
	"testing"
)

func TestStatusLabel(t *testing.T) {
	t.Parallel()
	cases := map[Status]string{
		StatusActive: "On the board",
		StatusWIP:    "Drafts",
		StatusDone:   "Turned in",
	}
	for status, want := range cases {
		if got := StatusLabel(status); got != want {
			t.Errorf("StatusLabel(%q) = %q, want %q", status, got, want)
		}
	}
}

func TestGroupByProject(t *testing.T) {
	t.Parallel()
	quests := []Quest{
		{ID: "loose-2", Status: StatusActive},                  // no project → Unsorted
		{ID: "zed-1", Status: StatusActive, Project: "zed"},    // later project
		{ID: "alpha-wip", Status: StatusWIP, Project: "alpha"}, // same project, lower status
		{ID: "alpha-act", Status: StatusActive, Project: "alpha"},
		{ID: "alpha-done", Status: StatusDone, Project: "alpha"},
		{ID: "loose-1", Status: StatusWIP},
	}

	groups := GroupByProject(quests)

	wantProjects := []string{"alpha", "zed", UnsortedProject}
	gotProjects := make([]string, len(groups))
	for i, g := range groups {
		gotProjects[i] = g.Project
	}
	if !reflect.DeepEqual(gotProjects, wantProjects) {
		t.Fatalf("project order = %v, want %v (alphabetical, Unsorted last)", gotProjects, wantProjects)
	}

	// Within "alpha": active → wip → done.
	wantAlpha := []string{"alpha-act", "alpha-wip", "alpha-done"}
	if got := ids(groups[0].Quests); !reflect.DeepEqual(got, wantAlpha) {
		t.Errorf("alpha rows = %v, want %v (status order)", got, wantAlpha)
	}

	// Unsorted keeps the same status-then-id order: active loose-2 before wip loose-1.
	wantUnsorted := []string{"loose-2", "loose-1"}
	if got := ids(groups[2].Quests); !reflect.DeepEqual(got, wantUnsorted) {
		t.Errorf("Unsorted rows = %v, want %v", got, wantUnsorted)
	}
}

func TestGroupByProjectSameStatusSortsByID(t *testing.T) {
	t.Parallel()
	quests := []Quest{
		{ID: "b", Status: StatusActive, Project: "p"},
		{ID: "a", Status: StatusActive, Project: "p"},
	}
	groups := GroupByProject(quests)
	if len(groups) != 1 {
		t.Fatalf("got %d groups, want 1", len(groups))
	}
	if got := ids(groups[0].Quests); !reflect.DeepEqual(got, []string{"a", "b"}) {
		t.Errorf("same-status rows = %v, want [a b] (id order)", got)
	}
}

func ids(qs []Quest) []string {
	out := make([]string, len(qs))
	for i, q := range qs {
		out[i] = q.ID
	}
	return out
}
