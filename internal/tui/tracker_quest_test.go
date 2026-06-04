package tui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/x/ansi"
)

// TestTrackerQuestLine asserts the per-session quest line ("⚑ id · goal")
// renders for attached masters and standalones and for nothing else.
func TestTrackerQuestLine(t *testing.T) {
	cases := []struct {
		name     string
		row      SessionRow
		wantLine bool
	}{
		{
			name:     "attached master",
			row:      SessionRow{ID: "qm-1", Title: "Widget", Status: "active", SessionType: "master", QuestID: "DEMO-1", QuestTitle: "Widget shell refactor"},
			wantLine: true,
		},
		{
			name:     "attached standalone",
			row:      SessionRow{ID: "qm-2", Title: "Solo", Status: "active", SessionType: "standalone", QuestID: "ENG-9", QuestTitle: "Fix the loop"},
			wantLine: true,
		},
		{
			name:     "worker (inherits, no line)",
			row:      SessionRow{ID: "qm-3", Title: "Worker", Status: "active", SessionType: "worker", ParentID: "qm-1", QuestID: "DEMO-1", QuestTitle: "Widget shell refactor"},
			wantLine: false,
		},
		{
			name:     "free session (no quest)",
			row:      SessionRow{ID: "qm-4", Title: "Errand", Status: "active", SessionType: "standalone"},
			wantLine: false,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			tm := TrackerModel{sessions: []SessionRow{c.row}}
			got := ansi.Strip(tm.renderSessionRow(c.row, 0, 60))
			hasLine := strings.Contains(got, "⚑")
			if hasLine != c.wantLine {
				t.Fatalf("quest line present=%v, want %v\n%s", hasLine, c.wantLine, got)
			}
			if c.wantLine {
				if !strings.Contains(got, c.row.QuestID) {
					t.Errorf("quest line missing id %q\n%s", c.row.QuestID, got)
				}
				if !strings.Contains(got, c.row.QuestTitle) {
					t.Errorf("quest line missing goal %q\n%s", c.row.QuestTitle, got)
				}
				// No status badge on the tracker line.
				if strings.Contains(got, "active ") && strings.Contains(got, "⚑") {
					// the row title may carry state, but the quest line itself
					// must not add a status word; ensure "wip/done/active" tags
					// from the list renderer are absent on the ⚑ line.
					for _, line := range strings.Split(got, "\n") {
						if strings.Contains(line, "⚑") && (strings.Contains(line, "wait") || strings.Contains(line, "wip") || strings.Contains(line, "done")) {
							t.Errorf("quest line carries a status tag: %q", line)
						}
					}
				}
			}
		})
	}
}
