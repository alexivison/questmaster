package tui

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"

	"github.com/alexivison/questmaster/internal/quests/quest"
)

// TestTrackerQuestLine asserts the per-session quest line ("⚑ id · goal")
// renders for every explicitly attached session.
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
			name:     "explicitly attached worker",
			row:      SessionRow{ID: "qm-3", Title: "Worker", Status: "active", SessionType: "worker", ParentID: "qm-1", QuestID: "DEMO-1", QuestTitle: "Widget shell refactor"},
			wantLine: true,
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

func TestTrackerQuestLoopIndicator(t *testing.T) {
	tm := TrackerModel{}
	row := SessionRow{
		ID:           "qm-loop",
		Title:        "Loop",
		Status:       "active",
		SessionType:  "worker",
		ParentID:     "qm-master",
		QuestID:      "LOOP-1",
		QuestTitle:   "Fix autos",
		QuestLoop:    &quest.LoopRuntime{SessionID: "qm-loop", Iterations: 2, LastVerdict: "fail"},
		PrimaryAgent: "codex",
		State:        "idle",
	}

	got := ansi.Strip(tm.renderSessionRow(row, 0, 80))
	t.Logf("tracker row:\n%s", got)
	if !strings.Contains(got, "↻ loop i2 fail") {
		t.Fatalf("loop indicator missing from tracker row:\n%s", got)
	}
	if !strings.Contains(got, "LOOP-1") {
		t.Fatalf("quest id missing from tracker row:\n%s", got)
	}

	row.QuestLoop = nil
	got = ansi.Strip(tm.renderSessionRow(row, 0, 80))
	if strings.Contains(got, "↻ loop") {
		t.Fatalf("loop indicator rendered without marker:\n%s", got)
	}
}

func TestTrackerSelectedWorkerQuestLineHasNoDisplayGutter(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	row := SessionRow{
		ID:           "qm-worker",
		Title:        "Worker",
		Status:       "active",
		SessionType:  "worker",
		ParentID:     "qm-master",
		PrimaryAgent: "claude",
		State:        "idle",
		DisplayColor: "cyan",
		QuestID:      "DEMO-1",
		QuestTitle:   "Widget shell refactor",
	}
	tm := TrackerModel{
		cursor:   0,
		sessions: []SessionRow{row, {ID: "qm-sibling", SessionType: "worker", ParentID: "qm-master"}},
	}

	got := tm.renderSessionRow(row, 0, 64)
	lines := strings.Split(got, "\n")
	if len(lines) != 3 {
		t.Fatalf("selected worker with quest line count = %d, want 3\n%s", len(lines), got)
	}

	badGutter := selectedDisplayColorGutter(row.DisplayColor)
	if strings.HasPrefix(lines[1], badGutter) {
		t.Fatalf("selected worker quest line should not start with display-color gutter %q\nline %q\nrow:\n%s", badGutter, lines[1], got)
	}
	wantPrefix := renderTrackerANSI(selectedRowStyle.Inherit(lipgloss.NewStyle().Foreground(lipgloss.Color("6")).Bold(true)), "┃   ")
	if !strings.HasPrefix(lines[1], wantPrefix) {
		t.Fatalf("selected worker quest line should align under tree continuation\nwant prefix %q\ngot         %q", wantPrefix, lines[1])
	}
	if !strings.HasPrefix(ansi.Strip(lines[1]), "┃   ⚑ DEMO-1") {
		t.Fatalf("selected worker quest line has wrong plain alignment:\n%s", ansi.Strip(got))
	}
}
