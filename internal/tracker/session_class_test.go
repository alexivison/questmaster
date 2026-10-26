//go:build linux || darwin

package tracker

import "testing"

func TestWorkersInheritMasterClassOnEveryRefresh(t *testing.T) {
	t.Parallel()

	rows := []SessionRow{
		{ID: "qm-master", SessionType: "master", Class: "wizard"},
		{ID: "qm-worker", SessionType: "worker", ParentID: "qm-master"},
		{ID: "qm-shell", SessionType: "shell"},
	}
	InheritWorkerClasses(rows)
	if rows[1].Class != "wizard" || rows[2].Class != "" {
		t.Fatalf("first inherited classes = worker:%q shell:%q", rows[1].Class, rows[2].Class)
	}

	rows[0].Class = "bard"
	InheritWorkerClasses(rows)
	if rows[1].Class != "bard" {
		t.Fatalf("worker class after master reclass = %q, want bard", rows[1].Class)
	}
}
