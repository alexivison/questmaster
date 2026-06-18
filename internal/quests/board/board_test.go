package board

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"

	"github.com/alexivison/questmaster/internal/palette"
	"github.com/alexivison/questmaster/internal/quests/quest"
)

func strip(s string) string { return ansi.Strip(s) }

func newStore(t *testing.T) *quest.FileStore {
	t.Helper()
	return quest.NewStore(filepath.Join(t.TempDir(), "quests"))
}

type countingStore struct {
	*quest.FileStore
	saves int
}

func (s *countingStore) Save(q *quest.Quest) error {
	s.saves++
	return s.FileStore.Save(q)
}

func save(t *testing.T, s *quest.FileStore, id string, status quest.Status) {
	t.Helper()
	saveProj(t, s, id, status, "")
}

func saveProj(t *testing.T, s *quest.FileStore, id string, status quest.Status, project string) {
	t.Helper()
	q := &quest.Quest{ID: id, Title: id, Summary: "goal of " + id, Status: status, Project: project,
		Gates: []quest.Gate{{Name: "tests", Type: quest.GateAuto, Check: "cmd:make test"}}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save %s: %v", id, err)
	}
}

func key(s string) tea.KeyMsg {
	if len(s) == 1 {
		return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
	}
	return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)}
}

func keyType(typ tea.KeyType) tea.KeyMsg {
	return tea.KeyMsg{Type: typ}
}

func update(m Model, msg tea.Msg) (Model, tea.Cmd) {
	next, cmd := m.Update(msg)
	return next.(Model), cmd
}

func typeText(m Model, text string) Model {
	for _, r := range text {
		m, _ = update(m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	return m
}

func TestGroupsFromStore(t *testing.T) {
	s := newStore(t)
	// Active quests across projects (shown on the default Active tab) plus
	// some non-active that must NOT appear under the Active tab.
	saveProj(t, s, "ZED-1", quest.StatusActive, "zed")
	saveProj(t, s, "ALPHA-2", quest.StatusActive, "alpha")
	saveProj(t, s, "ALPHA-1", quest.StatusActive, "alpha")
	save(t, s, "LOOSE-1", quest.StatusActive) // no project → Unsorted
	saveProj(t, s, "ALPHA-WIP", quest.StatusWIP, "alpha")
	save(t, s, "DONE-1", quest.StatusDone)

	m := NewModel(s, nil, Commands{}) // default tab = Active
	groups := m.Groups()
	if len(groups) != 3 {
		t.Fatalf("got %d groups, want 3 (alpha, zed, Unsorted)", len(groups))
	}
	// Project sections: alphabetical, Unsorted last.
	if groups[0].Label != "alpha" || groups[1].Label != "zed" || groups[2].Label != "Unsorted" {
		t.Fatalf("group order = %q/%q/%q, want alpha/zed/Unsorted",
			groups[0].Label, groups[1].Label, groups[2].Label)
	}
	// Within a project, active rows in id order; the wip/done quests are hidden.
	if got := ids(groups[0].Quests); len(got) != 2 || got[0] != "ALPHA-1" || got[1] != "ALPHA-2" {
		t.Fatalf("alpha rows = %v, want [ALPHA-1 ALPHA-2] (active only, id order)", got)
	}
}

func TestDefaultTabIsActive(t *testing.T) {
	s := newStore(t)
	save(t, s, "WIP-1", quest.StatusWIP)
	save(t, s, "ACT-1", quest.StatusActive)
	save(t, s, "DONE-1", quest.StatusDone)

	m := NewModel(s, nil, Commands{})
	if m.tab != tabActive {
		t.Fatalf("default tab = %d, want tabActive (%d)", m.tab, tabActive)
	}
	if sel, ok := m.Selected(); !ok || sel.ID != "ACT-1" {
		t.Fatalf("default selection = %v/%q, want ACT-1", ok, sel.ID)
	}
	if len(m.visible) != 1 {
		t.Fatalf("Active tab shows %d quests, want 1 (only the active one)", len(m.visible))
	}
}

func TestTabFilteringShowsOnlyTabStatus(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	save(t, s, "WIP-1", quest.StatusWIP)
	save(t, s, "WIP-2", quest.StatusWIP)
	save(t, s, "DONE-1", quest.StatusDone)

	m := NewModel(s, nil, Commands{})
	m.setTab(tabDrafts)
	if got := ids(m.visible); len(got) != 2 || got[0] != "WIP-1" || got[1] != "WIP-2" {
		t.Errorf("Drafts tab visible = %v, want [WIP-1 WIP-2]", got)
	}
	m.setTab(tabDone)
	if got := ids(m.visible); len(got) != 1 || got[0] != "DONE-1" {
		t.Errorf("Done tab visible = %v, want [DONE-1]", got)
	}
}

func TestTabKeysCycleWithWrap(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	m := NewModel(s, nil, Commands{}) // start on Active

	m, _ = update(m, key("tab")) // Active → Done
	if m.tab != tabDone {
		t.Fatalf("after tab, tab = %d, want Done", m.tab)
	}
	m, _ = update(m, key("tab")) // Done → Drafts (wrap)
	if m.tab != tabDrafts {
		t.Fatalf("after tab wrap, tab = %d, want Drafts", m.tab)
	}
	m, _ = update(m, key("shift+tab")) // Drafts → Done (wrap back)
	if m.tab != tabDone {
		t.Fatalf("after shift+tab wrap, tab = %d, want Done", m.tab)
	}
}

func TestTabSwitchResetsCursor(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	save(t, s, "ACT-2", quest.StatusActive)
	save(t, s, "WIP-1", quest.StatusWIP)

	m := NewModel(s, nil, Commands{})
	m, _ = update(m, key("j")) // cursor on ACT-2
	if m.cursor != 1 {
		t.Fatalf("setup: cursor = %d, want 1", m.cursor)
	}
	m, _ = update(m, key("tab")) // switch tab → cursor resets
	if m.cursor != 0 {
		t.Errorf("cursor = %d after tab switch, want 0 (reset to top)", m.cursor)
	}
}

func TestAttachableQuestsStaysActiveAcrossTabs(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	save(t, s, "WIP-1", quest.StatusWIP)
	save(t, s, "DONE-1", quest.StatusDone)

	m := NewModel(s, nil, Commands{})
	// Switch to the Drafts tab; attach must still return the active quest.
	m, _ = update(m, key("tab"))
	m, _ = update(m, key("tab"))
	att := m.AttachableQuests()
	if len(att) != 1 || att[0].ID != "ACT-1" {
		t.Fatalf("AttachableQuests on a non-active tab = %v, want [ACT-1]", ids(att))
	}
}

func TestHLMovesBetweenPanesNotTabs(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "ACT-1", Title: "t", Summary: "s", Status: quest.StatusActive,
		Gates: []quest.Gate{{Name: "ui", Type: quest.GateToggle}}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})

	m, _ = update(m, key("l")) // l enters the detail pane
	if m.focus != focusDetail {
		t.Fatalf("'l' did not enter detail focus")
	}
	if m.tab != tabActive {
		t.Errorf("'l' should not change the tab")
	}
	m, _ = update(m, key("h")) // h returns to the list pane
	if m.focus != focusList {
		t.Fatalf("'h' did not return to list focus")
	}
}

func TestWIPExcludedFromAttachableSet(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	save(t, s, "WIP-1", quest.StatusWIP)
	save(t, s, "DONE-1", quest.StatusDone)

	m := NewModel(s, nil, Commands{})
	att := m.AttachableQuests()
	if len(att) != 1 || att[0].ID != "ACT-1" {
		t.Fatalf("AttachableQuests = %v, want [ACT-1] (wip and done excluded)", ids(att))
	}
}

func TestDetailPaneComesFromTerminalRenderer(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 120, 60

	sel, ok := m.Selected()
	if !ok {
		t.Fatal("no selection")
	}
	detailW := m.width - (m.width * 34 / 100) - 1
	// The board renders RenderDetail at the inner width (minus the outer gutter)
	// and left-pads each line; every non-blank T2 line must still appear.
	inner := detailW - detailPadLeft - detailPadRight
	want := strip(quest.RenderDetail(&sel, quest.Runtime{}, inner))
	got := strip(m.renderDetail(detailW, 60))
	for _, line := range strings.Split(want, "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		if !strings.Contains(got, line) {
			t.Errorf("board detail is not the T2 render — missing line %q\n got:\n%s", line, got)
		}
	}
}

func TestRefreshKeyReloadsQuestsAndRuntime(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)

	scans := 0
	var lastIDs []string
	runtimeFor := func(ids []string) map[string]quest.Runtime {
		scans++
		lastIDs = ids
		return map[string]quest.Runtime{"ACT-2": {Sessions: []string{"qm-2"}}}
	}
	m := NewModel(s, runtimeFor, Commands{})
	if scans != 1 {
		t.Fatalf("initial runtime scans = %d, want 1 (one pass, not one per quest)", scans)
	}

	save(t, s, "ACT-2", quest.StatusActive)
	m, _ = update(m, key("r"))
	if scans != 2 {
		t.Fatalf("runtime scans after refresh = %d, want 2 (one pass per reload)", scans)
	}
	if len(lastIDs) != 2 {
		t.Fatalf("refresh scan covered %d quests, want 2", len(lastIDs))
	}
	list := strip(m.renderList(44, 20))
	if !strings.Contains(list, "ACT-2") || !strings.Contains(list, "⚔") {
		t.Fatalf("refresh did not reload quest list and runtime:\n%s", list)
	}
	if !strings.Contains(m.footHint(), "r refresh") {
		t.Fatalf("footer missing refresh key hint: %q", m.footHint())
	}
}

func TestBoardTitleHasHorizontalPadding(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 80, 20

	firstLine := strings.Split(strip(m.View()), "\n")[0]
	if !strings.HasPrefix(firstLine, " Quests") || !strings.Contains(firstLine, "Quests ") {
		t.Fatalf("board title should have left and right padding, got %q", firstLine)
	}
}

func TestListRowsUseCompactTwoLineItems(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "ACT-1", Title: "Visible title", Summary: "s", Status: quest.StatusActive}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})

	lines := strings.Split(strip(m.renderList(44, 20)), "\n")
	titleRow, idRow := -1, -1
	for i, ln := range lines {
		if strings.Contains(ln, "Visible title") {
			titleRow = i
		}
		if strings.Contains(ln, "ACT-1") {
			idRow = i
		}
	}
	if titleRow <= 0 || idRow != titleRow+1 || idRow >= len(lines)-1 {
		t.Fatalf("could not find two-line row with title above id:\n%s", strings.Join(lines, "\n"))
	}
	if strings.TrimSpace(lines[titleRow-1]) == "" {
		t.Fatalf("quest row should not keep the old top padding:\n%s", strings.Join(lines, "\n"))
	}
}

func TestAttachedIndicatorFromRuntimeScan(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive) // on it
	save(t, s, "ACT-2", quest.StatusActive) // waiting

	runtimeFor := func(ids []string) map[string]quest.Runtime {
		return map[string]quest.Runtime{"ACT-1": {Sessions: []string{"qm-1"}}}
	}
	m := NewModel(s, runtimeFor, Commands{})
	list := strip(m.renderList(44, 20))

	// On the board, the right column is attached-only: ACT-1 shows ⚔; the idle
	// ACT-2 shows nothing. Status glyphs (◆/○/●) are gone — the tab conveys it.
	if !strings.Contains(list, "⚔") {
		t.Errorf("attached quest missing the on-it indicator:\n%s", list)
	}
	for _, glyph := range []string{"◆", "○", "●"} {
		if strings.Contains(list, glyph) {
			t.Errorf("board row should not show status glyph %q:\n%s", glyph, list)
		}
	}
}

func TestBoardListAndDetailShowOpenComments(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "ACT-1",
		Title:   "Commented",
		Summary: "s",
		Status:  quest.StatusActive,
		Gates:   []quest.Gate{{Name: "review", Type: quest.GateToggle}},
		Comments: []quest.QuestComment{
			{ID: "comment-1", Anchor: quest.CommentAnchor{Kind: quest.CommentAnchorGate, ID: "review"}, Status: quest.CommentOpen, Body: "needs sharper wording", CreatedAt: "2026-06-17T00:00:00Z"},
		},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 120, 40

	if list := strip(m.renderList(44, 20)); !strings.Contains(list, "✎ 1") || strings.Contains(list, "1 open") {
		t.Fatalf("board list should show compact open comment count:\n%s", list)
	}
	if detail := strip(m.renderDetail(80, 30)); !strings.Contains(detail, "comment-1") || !strings.Contains(detail, "needs sharper wording") {
		t.Fatalf("board detail missing inline comment:\n%s", detail)
	}
}

func TestBoardDetailShowsRuntimeAgent(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	runtimeFor := func(ids []string) map[string]quest.Runtime {
		return map[string]quest.Runtime{"ACT-1": {Sessions: []string{"qm-1"}, Agent: "claude"}}
	}
	m := NewModel(s, runtimeFor, Commands{})
	m.width, m.height = 120, 40

	detail := strip(m.renderDetail(80, 30))
	if !strings.Contains(detail, "claude") {
		t.Fatalf("board detail missing runtime-derived agent:\n%s", detail)
	}
}

func TestLoopIndicatorFromRuntime(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)

	runtimeFor := func(ids []string) map[string]quest.Runtime {
		return map[string]quest.Runtime{"ACT-1": {
			Sessions: []string{"qm-loop"},
			Loop:     &quest.LoopRuntime{SessionID: "qm-loop", Iterations: 3, LastVerdict: "fail"},
		}}
	}
	m := NewModel(s, runtimeFor, Commands{})
	m.width, m.height = 120, 40

	detail := strip(m.renderDetail(80, 30))
	t.Logf("board detail:\n%s", detail)
	if strings.Contains(detail, "↻ loop i3 fail") {
		t.Fatalf("detail should not render the loop section:\n%s", detail)
	}

	footer := strip(m.footHint())
	t.Logf("board footer:\n%s", footer)
	if !strings.Contains(footer, "↻ loop i3 fail armed") {
		t.Fatalf("footer missing loop mode:\n%s", footer)
	}

	m.runtime["ACT-1"] = quest.Runtime{}
	if got := strip(m.footHint()); strings.Contains(got, "↻ loop") {
		t.Fatalf("footer rendered loop mode without marker:\n%s", got)
	}
}

func TestStatusKeysMoveFreely(t *testing.T) {
	s := newStore(t)
	save(t, s, "Q-1", quest.StatusWIP)
	m := NewModel(s, nil, Commands{})

	// A status move sends the quest to another tab, so switch to the tab that
	// currently shows it before each move; verify the move via the store.
	// a → board (active), d → done, w → back to draft (wip): any direction.
	steps := []struct {
		startTab statusTab
		key      string
		want     quest.Status
	}{
		{tabDrafts, "a", quest.StatusActive}, // wip → active
		{tabActive, "d", quest.StatusDone},   // active → done
		{tabDone, "a", quest.StatusActive},   // done → back to the board
		{tabActive, "w", quest.StatusWIP},    // active → back to draft
		{tabDrafts, "d", quest.StatusDone},   // wip → straight to done
	}
	for _, st := range steps {
		m.setTab(st.startTab)
		if _, ok := m.Selected(); !ok {
			t.Fatalf("Q-1 not selectable on its tab before %q", st.key)
		}
		m, _ = update(m, key(st.key))
		if q, _ := s.Load("Q-1"); q.Status != st.want {
			t.Fatalf("after %q, stored status = %q, want %q", st.key, q.Status, st.want)
		}
	}
}

func TestDeleteKeyRemovesSelectedAndClampsCursor(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	save(t, s, "ACT-2", quest.StatusActive)
	save(t, s, "ACT-3", quest.StatusActive) // all on the default Active tab

	m := NewModel(s, nil, Commands{})
	m, _ = update(m, key("j"))
	m, _ = update(m, key("j")) // cursor on the last row, ACT-3
	if sel, _ := m.Selected(); sel.ID != "ACT-3" {
		t.Fatalf("setup: cursor on %q, want ACT-3", sel.ID)
	}

	m, _ = update(m, key("x")) // delete immediately

	if s.Exists("ACT-3") {
		t.Errorf("deleted quest still present in the store")
	}
	if len(m.visible) != 2 {
		t.Fatalf("after delete, %d visible, want 2", len(m.visible))
	}
	if m.cursor < 0 || m.cursor >= len(m.visible) {
		t.Errorf("cursor %d out of bounds after delete (len %d)", m.cursor, len(m.visible))
	}
	if _, ok := m.Selected(); !ok {
		t.Errorf("no valid selection after delete")
	}
}

func TestProjectHeaderIsFullWidthRule(t *testing.T) {
	const width = 40
	got := strip(projectHeader("questmaster", width))
	if ansi.StringWidth(got) != width {
		t.Errorf("header width = %d, want %d (%q)", ansi.StringWidth(got), width, got)
	}
	if !strings.HasPrefix(got, "── questmaster ─") {
		t.Errorf("header should read \"── name ─…\", got %q", got)
	}
	if !strings.HasSuffix(got, "─") {
		t.Errorf("header should fill to the right edge with the rule rune, got %q", got)
	}
}

func TestDeleteKeyNoOpOnEmptyBoard(t *testing.T) {
	s := newStore(t)
	m := NewModel(s, nil, Commands{})
	// No quests, no selection: pressing x must not panic or error.
	m, _ = update(m, key("x"))
	if m.lastErr != nil {
		t.Errorf("delete on an empty board surfaced an error: %v", m.lastErr)
	}
}

func TestDetailToggleFlipPersistsAndRebuilds(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "Q-1", Title: "Q-1", Summary: "s", Status: quest.StatusActive,
		Gates: []quest.Gate{
			{Name: "tests", Type: quest.GateAuto, Check: "cmd:make test"},
			{Name: "ui-ok", Type: quest.GateToggle},
		}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})

	// Enter the detail pane and move from the quest-level anchor through the
	// read-only auto gate to the toggle gate.
	m, _ = update(m, key("l"))
	m, _ = update(m, key("j"))
	m, _ = update(m, key("j"))
	tgt, ok := m.currentTarget()
	if !ok || tgt.Kind != quest.TargetGate || tgt.Index != 1 {
		t.Fatalf("expected a focused gate target, got %+v ok=%v", tgt, ok)
	}

	// Flip it.
	m, _ = update(m, key(" "))

	got, _ := s.Load("Q-1")
	checked := false
	for _, g := range got.Gates {
		if g.Name == "ui-ok" {
			checked = g.Checked
		}
		if g.Type == quest.GateAuto && g.Checked {
			t.Errorf("auto gate %q must never be checked", g.Name)
		}
	}
	if !checked {
		t.Fatalf("toggle gate not checked after flip: %+v", got.Gates)
	}
	// The rebuilt HTML reflects the flip.
	raw, _ := quest.Build(got)
	if !strings.Contains(string(raw), "[x]") {
		t.Errorf("rebuilt HTML missing the checked box")
	}
}

func TestDetailFocusNavigationAndExit(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "Q-1", Title: "Q-1", Summary: "s", Status: quest.StatusActive,
		Gates:   []quest.Gate{{Name: "a", Type: quest.GateToggle}, {Name: "b", Type: quest.GateToggle}},
		Related: []quest.RelatedLink{{Title: "NEXT-1"}}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	if m.focus != focusList {
		t.Fatalf("board should start in list focus")
	}
	m, _ = update(m, key("enter")) // enter now drills into the detail pane (no longer opens)
	if m.focus != focusDetail {
		t.Fatalf("enter did not enter detail focus")
	}
	m, _ = update(m, key("esc"))
	m, _ = update(m, key("l")) // l also enters detail
	if m.focus != focusDetail {
		t.Fatalf("'l' did not enter detail focus")
	}
	if hint := m.footHint(); !strings.Contains(hint, "m comment") || !strings.Contains(hint, "e edit comment") || !strings.Contains(hint, "D delete comment") || !strings.Contains(hint, "R resolve") {
		t.Fatalf("detail footer missing comment keys: %q", hint)
	}
	m, _ = update(m, key("j")) // move down three targets: quest → a → b → related
	m, _ = update(m, key("j"))
	m, _ = update(m, key("j"))
	if tgt, _ := m.currentTarget(); tgt.Kind != quest.TargetRelated {
		t.Errorf("after three downs, focus should be on the related entry, got %+v", tgt)
	}
	m, _ = update(m, key("esc")) // leave
	if m.focus != focusList {
		t.Errorf("esc did not return to list focus")
	}
	m, _ = update(m, key("l"))
	m, cmd := update(m, key("q"))
	if !m.quit || cmd == nil {
		t.Fatalf("q from detail should quit the board, quit=%v cmd nil=%v", m.quit, cmd == nil)
	}
}

func TestDetailNavigationIncludesAutoGatesWithoutToggling(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "Q-1", Title: "Q-1", Summary: "s", Status: quest.StatusActive,
		Gates: []quest.Gate{
			{Name: "tests", Type: quest.GateAuto, Check: "cmd:go test ./..."},
			{Name: "ui-ok", Type: quest.GateToggle},
		}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})

	m, _ = update(m, key("l"))
	m, _ = update(m, key("j")) // quest -> auto gate
	tgt, ok := m.currentTarget()
	if !ok || tgt.Kind != quest.TargetGate || tgt.Index != 0 {
		t.Fatalf("first gate target = %+v ok=%v, want auto gate index 0", tgt, ok)
	}
	m, _ = update(m, key(" "))
	got, _ := s.Load("Q-1")
	if got.Gates[0].Checked {
		t.Fatalf("space toggled auto gate: %#v", got.Gates[0])
	}

	m, _ = update(m, key("j")) // auto gate -> toggle gate
	tgt, ok = m.currentTarget()
	if !ok || tgt.Kind != quest.TargetGate || tgt.Index != 1 {
		t.Fatalf("second gate target = %+v ok=%v, want toggle gate index 1", tgt, ok)
	}
	m, _ = update(m, key(" "))
	got, _ = s.Load("Q-1")
	if !got.Gates[1].Checked {
		t.Fatalf("space did not toggle toggle gate: %#v", got.Gates[1])
	}
}

func TestRelatedOpensURLNoWrite(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "Q-1", Title: "Q-1", Summary: "s", Status: quest.StatusActive,
		Related: []quest.RelatedLink{
			{Type: "linear", Title: "NEXT-1", URL: "https://linear.app/x/NEXT-1"},
			{Type: "github", Title: "PR-9", URL: "https://github.com/x/y/pull/9"},
		}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	before := mustReadFile(t, s.Path("Q-1"))

	var opened string
	openURL := func(url string) tea.Cmd { return func() tea.Msg { opened = url; return nil } }
	m := NewModel(s, nil, Commands{OpenURL: openURL})

	m, _ = update(m, key("l")) // detail focus → quest anchor (no toggle gates here)
	m, _ = update(m, key("j")) // first related entry
	m, _ = update(m, key("j")) // second related entry
	_, cmd := update(m, key("o"))
	if cmd == nil {
		t.Fatal("opening a related entry produced no command")
	}
	cmd()
	if opened != "https://github.com/x/y/pull/9" {
		t.Errorf("opener got %q, want the focused entry's url", opened)
	}
	// Opening is read-only: the quest file is untouched.
	if after := mustReadFile(t, s.Path("Q-1")); after != before {
		t.Errorf("opening a related entry rewrote the quest file")
	}
}

func TestCommentKeyOpensComposerForFocusedAnchor(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Gates:   []quest.Gate{{Name: "review", Type: quest.GateToggle}},
		Related: []quest.RelatedLink{{ID: "rel-1", Title: "TASK-1"}},
		Body: []quest.Block{
			{ID: "block-1", Type: quest.BlockText, Text: "body"},
			{ID: "block-2", Type: quest.BlockList, Items: []string{"first item", "second item"}},
		},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 120, 40

	m, _ = update(m, key("l")) // quest anchor
	for _, want := range []string{"quest", "gate:review", "related:rel-1", "block:block-1", "block:block-2#item:0"} {
		var cmd tea.Cmd
		m, cmd = update(m, key("m"))
		if cmd != nil {
			t.Fatalf("m produced command for %q; composer should stay in-board", want)
		}
		if m.composer == nil {
			t.Fatalf("m did not open composer for %q", want)
		}
		if m.composer.QuestID != "Q-1" || m.composer.Anchor.String() != want {
			t.Fatalf("composer = %q %q, want Q-1 %q", m.composer.QuestID, m.composer.Anchor.String(), want)
		}
		if m.composer.Editor.Placeholder != "" {
			t.Fatalf("composer placeholder = %q, want empty", m.composer.Editor.Placeholder)
		}
		m, _ = update(m, key("esc"))
		if m.composer != nil {
			t.Fatalf("esc did not cancel composer for %q", want)
		}
		m, _ = update(m, key("j"))
	}
}

func TestCommentComposerCancelLeavesQuestUnchanged(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "Q-1", Title: "Q-1", Summary: "s", Status: quest.StatusActive}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 100, 30

	m, _ = update(m, key("l"))
	m, _ = update(m, key("m"))
	m = typeText(m, "draft comment")
	m, _ = update(m, key("esc"))

	if m.composer != nil {
		t.Fatal("esc left composer active")
	}
	got, err := s.Load("Q-1")
	if err != nil {
		t.Fatalf("load after cancel: %v", err)
	}
	if len(got.Comments) != 0 {
		t.Fatalf("cancel persisted comments: %#v", got.Comments)
	}
}

func TestCommentComposerSavesTypedComment(t *testing.T) {
	base := newStore(t)
	q := &quest.Quest{ID: "Q-1", Title: "Q-1", Summary: "s", Status: quest.StatusActive}
	if err := base.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	s := &countingStore{FileStore: base}
	fixed := time.Unix(1780540000, 0).UTC()
	m := NewModel(s, nil, Commands{
		Now:    func() time.Time { return fixed },
		Author: func() string { return "aleksi" },
	})
	m.width, m.height = 100, 30

	m, _ = update(m, key("l"))
	m, _ = update(m, key("m"))
	m = typeText(m, "hellp")
	m, _ = update(m, keyType(tea.KeyBackspace))
	m = typeText(m, "o")
	m, _ = update(m, keyType(tea.KeyCtrlJ))
	m = typeText(m, "world")
	m, _ = update(m, keyType(tea.KeyEnter))

	if m.composer != nil {
		t.Fatal("enter left composer active")
	}
	if s.saves != 1 {
		t.Fatalf("submit saved %d times, want exactly one save", s.saves)
	}
	got, err := s.Load("Q-1")
	if err != nil {
		t.Fatalf("load after save: %v", err)
	}
	if err := quest.Validate(got); err != nil {
		t.Fatalf("saved quest is invalid: %v", err)
	}
	if len(got.Comments) != 1 {
		t.Fatalf("comments = %#v, want one", got.Comments)
	}
	c := got.Comments[0]
	if c.ID != "comment-1780540000" || c.Anchor.String() != "quest" || c.Status != quest.CommentOpen || c.Author != "aleksi" {
		t.Fatalf("stored comment metadata mismatch: %#v", c)
	}
	if c.Body != "hello\nworld" {
		t.Fatalf("stored body = %q, want hello newline world", c.Body)
	}
	if c.CreatedAt != "2026-06-04T02:26:40Z" {
		t.Fatalf("created_at = %q, want fixed time", c.CreatedAt)
	}
}

func TestCommentComposerCtrlSSavesOnFirstPress(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "Q-1", Title: "Q-1", Summary: "s", Status: quest.StatusActive}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{
		Now: func() time.Time { return time.Unix(1780540001, 0).UTC() },
	})
	m.width, m.height = 100, 30

	m, _ = update(m, key("l"))
	m, _ = update(m, key("m"))
	m = typeText(m, "single submit")
	m, _ = update(m, keyType(tea.KeyCtrlS))

	if m.composer != nil {
		t.Fatal("ctrl+s left composer active after one press")
	}
	got, err := s.Load("Q-1")
	if err != nil {
		t.Fatalf("load after ctrl+s: %v", err)
	}
	if len(got.Comments) != 1 || got.Comments[0].Body != "single submit" {
		t.Fatalf("ctrl+s did not save the comment on first press: %#v", got.Comments)
	}
}

func TestCommentComposerNewlineFallbackKeysAreDistinct(t *testing.T) {
	if got := (tea.KeyMsg{Type: tea.KeyEnter}).String(); got != "enter" {
		t.Fatalf("KeyEnter string = %q, want enter", got)
	}
	if got := (tea.KeyMsg{Type: tea.KeyCtrlJ}).String(); got != "ctrl+j" {
		t.Fatalf("KeyCtrlJ string = %q, want ctrl+j", got)
	}
	if got := (tea.KeyMsg{Type: tea.KeyEnter, Alt: true}).String(); got != "alt+enter" {
		t.Fatalf("Alt+Enter string = %q, want alt+enter", got)
	}
}

func TestCommentComposerAltEnterInsertsNewline(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "Q-1", Title: "Q-1", Summary: "s", Status: quest.StatusActive}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 100, 30

	m, _ = update(m, key("l"))
	m, _ = update(m, key("m"))
	m = typeText(m, "one")
	m, _ = update(m, tea.KeyMsg{Type: tea.KeyEnter, Alt: true})
	m = typeText(m, "two")

	if m.composer == nil {
		t.Fatal("alt+enter should not submit the composer")
	}
	if got := m.composer.Editor.Value(); got != "one\ntwo" {
		t.Fatalf("composer body after alt+enter = %q, want one newline two", got)
	}
}

func TestCommentComposerViewShowsAnchorDraftAndHints(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Gates:   []quest.Gate{{Name: "review", Type: quest.GateToggle}},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 120, 30

	m, _ = update(m, key("l")) // quest target
	m, _ = update(m, key("j")) // review gate
	m, _ = update(m, key("m"))
	m = typeText(m, "tighten acceptance")

	view := strip(m.View())
	for _, want := range []string{"new comment", "tighten acceptance", "enter post", "alt+enter newline", "ctrl+j newline", "esc cancel"} {
		if !strings.Contains(view, want) {
			t.Fatalf("composer view missing %q:\n%s", want, view)
		}
	}
	for _, notWant := range []string{"status: open", "anchor gate:review", "Write a comment", "shift+enter"} {
		if strings.Contains(view, notWant) {
			t.Fatalf("composer view should not include %q:\n%s", notWant, view)
		}
	}
	if !strings.Contains(view, "╭") || !strings.Contains(view, "╰") {
		t.Fatalf("composer view should render a bordered panel:\n%s", view)
	}
	if strings.Contains(view, "│tighten acceptance") || strings.Contains(view, "tighten acceptance│") {
		t.Fatalf("composer input text should have horizontal padding:\n%s", view)
	}
}

func TestResolveKeyResolvesFocusedOpenComment(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Comments: []quest.QuestComment{{
			ID:        "comment-1",
			Anchor:    quest.CommentAnchor{Kind: quest.CommentAnchorQuest},
			Status:    quest.CommentOpen,
			Body:      "done now",
			CreatedAt: "2026-06-17T00:00:00Z",
		}},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	resolve := func(id, commentID string) tea.Cmd {
		return func() tea.Msg {
			cur, err := s.Load(id)
			if err != nil {
				return ErrCmd(err)
			}
			for i := range cur.Comments {
				if cur.Comments[i].ID == commentID {
					cur.Comments[i].Status = quest.CommentResolved
					cur.Comments[i].ResolvedAt = "2026-06-17T00:01:00Z"
				}
			}
			if err := s.Save(cur); err != nil {
				return ErrCmd(err)
			}
			return ReloadCmd()
		}
	}
	m := NewModel(s, nil, Commands{ResolveComment: resolve})
	m.width, m.height = 120, 40
	m, _ = update(m, key("l")) // quest anchor
	m, _ = update(m, key("j")) // open comment row

	_, cmd := update(m, key("R"))
	if cmd == nil {
		t.Fatal("R produced no command for focused comment")
	}
	m, _ = update(m, cmd())
	got, _ := s.Load("Q-1")
	if got.Comments[0].Status != quest.CommentResolved || got.Comments[0].ResolvedAt == "" {
		t.Fatalf("comment not resolved: %#v", got.Comments[0])
	}
	if detail := strip(m.renderDetail(80, 30)); strings.Contains(detail, "comment-1") {
		t.Fatalf("resolved comment should be hidden from inline detail:\n%s", detail)
	}
}

func TestEditKeyEditsFocusedOpenComment(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Comments: []quest.QuestComment{{
			ID:        "comment-1",
			Anchor:    quest.CommentAnchor{Kind: quest.CommentAnchorQuest},
			Status:    quest.CommentOpen,
			Body:      "old body",
			CreatedAt: "2026-06-17T00:00:00Z",
		}},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 120, 40
	m, _ = update(m, key("l")) // quest anchor
	m, _ = update(m, key("j")) // open comment row

	var cmd tea.Cmd
	m, cmd = update(m, key("e"))
	if cmd != nil {
		t.Fatal("e should open an in-app composer, not return an external command")
	}
	if m.composer == nil {
		t.Fatal("e did not open the comment edit composer")
	}
	if m.composer.CommentID != "comment-1" {
		t.Fatalf("composer comment id = %q, want comment-1", m.composer.CommentID)
	}
	if got := m.composer.Editor.Value(); got != "old body" {
		t.Fatalf("composer initial value = %q, want old body", got)
	}
	if view := strip(m.View()); !strings.Contains(view, "edit comment") || strings.Contains(view, "new comment") {
		t.Fatalf("edit composer view should be labelled as edit comment:\n%s", view)
	}
	m, _ = update(m, keyType(tea.KeyCtrlJ))
	m = typeText(m, "second line")
	m, _ = update(m, keyType(tea.KeyEnter))
	got, _ := s.Load("Q-1")
	if got.Comments[0].Body != "old body\nsecond line" {
		t.Fatalf("comment body = %q, want edited body with newline", got.Comments[0].Body)
	}
	detail := strip(m.renderDetail(80, 30))
	if !strings.Contains(detail, "second line") {
		t.Fatalf("detail did not refresh edited comment:\n%s", detail)
	}
}

func TestCommentEditComposerCancelAndEmptyBody(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Comments: []quest.QuestComment{{
			ID:        "comment-1",
			Anchor:    quest.CommentAnchor{Kind: quest.CommentAnchorQuest},
			Status:    quest.CommentOpen,
			Body:      "keep body",
			CreatedAt: "2026-06-17T00:00:00Z",
		}},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 120, 40
	m, _ = update(m, key("l"))
	m, _ = update(m, key("j"))
	m, _ = update(m, key("e"))
	m.composer.Editor.SetValue("discarded")
	m, _ = update(m, key("esc"))
	got, _ := s.Load("Q-1")
	if got.Comments[0].Body != "keep body" {
		t.Fatalf("cancel changed body to %q", got.Comments[0].Body)
	}

	m, _ = update(m, key("e"))
	m.composer.Editor.SetValue(" \n")
	m, _ = update(m, keyType(tea.KeyEnter))
	if m.composer == nil {
		t.Fatal("empty edit should keep composer open")
	}
	if m.lastErr == nil || !strings.Contains(m.lastErr.Error(), "body is empty") {
		t.Fatalf("empty edit error = %v, want body is empty", m.lastErr)
	}
	got, _ = s.Load("Q-1")
	if got.Comments[0].Body != "keep body" {
		t.Fatalf("empty edit changed body to %q", got.Comments[0].Body)
	}
}

func TestDeleteKeyDeletesFocusedOpenComment(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Comments: []quest.QuestComment{{
			ID:        "comment-1",
			Anchor:    quest.CommentAnchor{Kind: quest.CommentAnchorQuest},
			Status:    quest.CommentOpen,
			Body:      "remove me",
			CreatedAt: "2026-06-17T00:00:00Z",
		}},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	deleteComment := func(id, commentID string) tea.Cmd {
		return func() tea.Msg {
			cur, err := s.Load(id)
			if err != nil {
				return ErrCmd(err)
			}
			if err := quest.DeleteComment(cur, commentID); err != nil {
				return ErrCmd(err)
			}
			if err := s.Save(cur); err != nil {
				return ErrCmd(err)
			}
			return ReloadCmd()
		}
	}
	m := NewModel(s, nil, Commands{DeleteComment: deleteComment})
	m.width, m.height = 120, 40
	m, _ = update(m, key("l")) // quest anchor
	m, _ = update(m, key("j")) // open comment row

	_, cmd := update(m, key("D"))
	if cmd == nil {
		t.Fatal("D produced no command for focused comment")
	}
	m, _ = update(m, cmd())
	got, _ := s.Load("Q-1")
	if len(got.Comments) != 0 {
		t.Fatalf("comments after delete = %#v, want empty", got.Comments)
	}
	if detail := strip(m.renderDetail(80, 30)); strings.Contains(detail, "comment-1") || strings.Contains(detail, "remove me") {
		t.Fatalf("detail should not show deleted comment:\n%s", detail)
	}
}

func TestCommentKeyNoOpOnFocusedCommentRow(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Comments: []quest.QuestComment{{
			ID:        "comment-1",
			Anchor:    quest.CommentAnchor{Kind: quest.CommentAnchorQuest},
			Status:    quest.CommentOpen,
			Body:      "do not nest from here",
			CreatedAt: "2026-06-17T00:00:00Z",
		}},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})

	m, _ = update(m, key("l")) // quest target
	m, _ = update(m, key("j")) // open comment row
	tgt, ok := m.currentTarget()
	if !ok || tgt.Kind != quest.TargetComment {
		t.Fatalf("setup target = %+v ok=%v, want comment row", tgt, ok)
	}
	m, cmd := update(m, key("m"))
	if cmd != nil {
		cmd()
	}
	if m.composer != nil {
		t.Fatal("m on a focused comment row opened a nested composer")
	}
}

func TestDetailNavigationReachesBodyBlocksWithoutIDs(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Gates: []quest.Gate{
			{Name: "tests", Type: quest.GateAuto, Check: "cmd:make test"},
			{Name: "review", Type: quest.GateToggle},
		},
		Body: []quest.Block{
			{Type: quest.BlockHeading, Level: 2, Text: "Context"},
			{Type: quest.BlockText, Text: "scaffold body text"},
			{Type: quest.BlockHeading, Level: 2, Text: "Approach"},
			{Type: quest.BlockList, Items: []string{"first step", "second step"}},
		},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 120, 12

	m, _ = update(m, key("l")) // quest target
	for i := 0; i < 5; i++ {
		m, _ = update(m, key("j")) // tests -> review -> Context -> text -> Approach
	}
	tgt, ok := m.currentTarget()
	if !ok || tgt.Kind != quest.TargetBody || tgt.Index != 2 {
		t.Fatalf("detail navigation target = %+v ok=%v, want body block Approach at index 2", tgt, ok)
	}
	if detail := strip(m.renderDetail(80, 12)); !strings.Contains(detail, "Approach") {
		t.Fatalf("focused body section is not visible in detail render:\n%s", detail)
	}
}

func TestCommentComposerCancelLeavesUnanchoredBodyBlockUnchanged(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Body:    []quest.Block{{Type: quest.BlockHeading, Level: 2, Text: "Context"}},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 100, 30

	m, _ = update(m, key("l")) // quest target
	m, _ = update(m, key("j")) // unanchored body heading
	m, cmd := update(m, key("m"))
	if cmd != nil {
		t.Fatal("m produced command for an unanchored body block; composer should stay in-board")
	}
	if m.composer == nil {
		t.Fatal("m did not open composer for an unanchored body block")
	}
	if m.composer.QuestID != "Q-1" || m.composer.Anchor.String() != "block:block-1" {
		t.Fatalf("composer = %q %q, want Q-1 block:block-1", m.composer.QuestID, m.composer.Anchor.String())
	}
	reloaded, err := s.Load("Q-1")
	if err != nil {
		t.Fatalf("load after m: %v", err)
	}
	if reloaded.Body[0].ID != "" {
		t.Fatalf("m should not persist body block id before submit, got %q", reloaded.Body[0].ID)
	}

	m, _ = update(m, key("esc"))
	reloaded, err = s.Load("Q-1")
	if err != nil {
		t.Fatalf("load after cancel: %v", err)
	}
	if reloaded.Body[0].ID != "" || len(reloaded.Comments) != 0 {
		t.Fatalf("cancel mutated quest: body id %q comments %#v", reloaded.Body[0].ID, reloaded.Comments)
	}
}

func TestCommentComposerSavesGeneratedBodyAnchorOnSubmit(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Body:    []quest.Block{{Type: quest.BlockHeading, Level: 2, Text: "Context"}},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{
		Now: func() time.Time { return time.Unix(1780540300, 0).UTC() },
	})
	m.width, m.height = 100, 30

	m, _ = update(m, key("l")) // quest target
	m, _ = update(m, key("j")) // unanchored body heading
	m, _ = update(m, key("m"))
	m = typeText(m, "body note")
	m, _ = update(m, keyType(tea.KeyEnter))

	got, err := s.Load("Q-1")
	if err != nil {
		t.Fatalf("load after submit: %v", err)
	}
	if got.Body[0].ID != "block-1" {
		t.Fatalf("body block id = %q, want block-1", got.Body[0].ID)
	}
	if len(got.Comments) != 1 || got.Comments[0].Anchor.String() != "block:block-1" {
		t.Fatalf("comment anchor mismatch: %#v", got.Comments)
	}
	if err := quest.Validate(got); err != nil {
		t.Fatalf("saved quest is invalid: %v", err)
	}
}

func TestCommentComposerCancelLeavesUnanchoredListItemUnchanged(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Body: []quest.Block{
			{Type: quest.BlockHeading, Level: 2, Text: "Approach"},
			{Type: quest.BlockList, Items: []string{"first step", "second step"}},
		},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 100, 30

	m, _ = update(m, key("l")) // quest target
	m, _ = update(m, key("j")) // heading
	m, _ = update(m, key("j")) // first list item
	tgt, ok := m.currentTarget()
	if !ok || tgt.Kind != quest.TargetListItem || tgt.Index != 1 || tgt.ItemIndex != 0 {
		t.Fatalf("setup target = %+v ok=%v, want first list item", tgt, ok)
	}
	m, cmd := update(m, key("m"))
	if cmd != nil {
		t.Fatal("m produced command for a list item; composer should stay in-board")
	}
	if m.composer == nil {
		t.Fatal("m did not open composer for a list item")
	}
	if m.composer.QuestID != "Q-1" || m.composer.Anchor.String() != "block:block-2#item:0" {
		t.Fatalf("composer = %q %q, want Q-1 block:block-2#item:0", m.composer.QuestID, m.composer.Anchor.String())
	}
	reloaded, err := s.Load("Q-1")
	if err != nil {
		t.Fatalf("load after m: %v", err)
	}
	if reloaded.Body[1].ID != "" {
		t.Fatalf("m should not persist parent list block id before submit, got %q", reloaded.Body[1].ID)
	}

	m, _ = update(m, key("esc"))
	reloaded, err = s.Load("Q-1")
	if err != nil {
		t.Fatalf("load after cancel: %v", err)
	}
	if reloaded.Body[1].ID != "" || len(reloaded.Comments) != 0 {
		t.Fatalf("cancel mutated quest: body id %q comments %#v", reloaded.Body[1].ID, reloaded.Comments)
	}
}

func TestCommentComposerSavesGeneratedListItemAnchorOnSubmit(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Body: []quest.Block{
			{Type: quest.BlockHeading, Level: 2, Text: "Approach"},
			{Type: quest.BlockList, Items: []string{"first step", "second step"}},
		},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{
		Now: func() time.Time { return time.Unix(1780540301, 0).UTC() },
	})
	m.width, m.height = 100, 30

	m, _ = update(m, key("l")) // quest target
	m, _ = update(m, key("j")) // heading
	m, _ = update(m, key("j")) // first list item
	m, _ = update(m, key("m"))
	m = typeText(m, "first item note")
	m, _ = update(m, keyType(tea.KeyEnter))

	got, err := s.Load("Q-1")
	if err != nil {
		t.Fatalf("load after submit: %v", err)
	}
	if got.Body[1].ID != "block-2" {
		t.Fatalf("parent list block id = %q, want block-2", got.Body[1].ID)
	}
	if len(got.Comments) != 1 || got.Comments[0].Anchor.String() != "block:block-2#item:0" {
		t.Fatalf("comment anchor mismatch: %#v", got.Comments)
	}
	if err := quest.Validate(got); err != nil {
		t.Fatalf("saved quest is invalid: %v", err)
	}
}

func TestCommentComposerSavesListItemAnchor(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Body: []quest.Block{{
			ID:    "steps",
			Type:  quest.BlockList,
			Items: []string{"first step", "second step"},
		}},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{
		Now: func() time.Time { return time.Unix(1780540200, 0).UTC() },
	})
	m.width, m.height = 100, 30

	m, _ = update(m, key("l")) // quest target
	m, _ = update(m, key("j")) // first list item
	m, _ = update(m, key("j")) // second list item
	m, _ = update(m, key("m"))
	m = typeText(m, "second item note")
	m, _ = update(m, keyType(tea.KeyEnter))

	got, err := s.Load("Q-1")
	if err != nil {
		t.Fatalf("load after save: %v", err)
	}
	if len(got.Comments) != 1 {
		t.Fatalf("comments = %#v, want one", got.Comments)
	}
	if got.Comments[0].Anchor.String() != "block:steps#item:1" {
		t.Fatalf("comment anchor = %q, want block:steps#item:1", got.Comments[0].Anchor.String())
	}
	if err := quest.Validate(got); err != nil {
		t.Fatalf("saved quest is invalid: %v", err)
	}
	detail := strip(m.renderDetail(80, 30))
	second := strings.Index(detail, "second step")
	note := strings.Index(detail, "second item note")
	if second < 0 || note < 0 || note < second {
		t.Fatalf("list item comment not rendered below the item:\n%s", detail)
	}
}

func mustReadFile(t *testing.T, path string) string {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	return string(b)
}

func TestCheckKeyDispatch(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)

	var checked string
	check := func(id string) tea.Cmd { return func() tea.Msg { checked = id; return nil } }
	m := NewModel(s, nil, Commands{Check: check})

	_, cmd := update(m, key("c"))
	if cmd == nil {
		t.Fatal("check produced no command")
	}
	cmd()
	if checked != "ACT-1" {
		t.Errorf("check dispatched for %q, want ACT-1", checked)
	}
}

// TestCheckErrorShowsInFooter asserts an injected command's failure (e.g.
// `check` on an unattached quest) is surfaced via ErrCmd instead of vanishing.
func TestCheckErrorShowsInFooter(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)

	check := func(id string) tea.Cmd {
		return func() tea.Msg { return ErrCmd(errors.New("attach it to a session first")) }
	}
	m := NewModel(s, nil, Commands{Check: check})
	m.width, m.height = 120, 40

	_, cmd := update(m, key("c"))
	if cmd == nil {
		t.Fatal("check produced no command")
	}
	m, _ = update(m, cmd()) // deliver the ErrCmd message
	if m.lastErr == nil || !strings.Contains(m.lastErr.Error(), "attach it to a session first") {
		t.Fatalf("check failure not surfaced: lastErr = %v", m.lastErr)
	}
	if !strings.Contains(m.View(), "attach it to a session first") {
		t.Errorf("error not shown in footer:\n%s", m.View())
	}
}

func TestDetailPaneScrollsWithoutInteractiveRows(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{
		ID:      "LONG-1",
		Title:   "Long detail",
		Summary: "s",
		Status:  quest.StatusActive,
		Body: []quest.Block{{
			Type: quest.BlockText,
			Text: strings.Repeat("line ", 240),
		}},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}

	m := NewModel(s, nil, Commands{})
	m.width, m.height = 100, 10
	m, _ = update(m, key("l"))
	if m.focus != focusDetail {
		t.Fatalf("detail pane did not accept focus without toggle/link rows")
	}

	m, _ = update(m, key("j")) // move from quest target to the body block
	m, _ = update(m, key("j")) // at the last target, keep scrolling
	if m.detailScroll == 0 {
		t.Fatalf("down key did not scroll a detail-only pane")
	}
	if !strings.Contains(m.footHint(), "pgup/pgdn scroll") {
		t.Fatalf("detail footer does not advertise scrolling: %q", m.footHint())
	}
}

// TestDetailScrollFollowsFocusedRow asserts the detail pane scrolls to keep the
// focused interactive row visible — on a tall quest, moving the cursor down
// must not leave the highlighted row outside a short viewport.
func TestDetailScrollFollowsFocusedRow(t *testing.T) {
	s := newStore(t)
	var gates []quest.Gate
	for i := 0; i < 12; i++ {
		gates = append(gates, quest.Gate{Name: fmt.Sprintf("g%02d", i), Type: quest.GateToggle})
	}
	q := &quest.Quest{ID: "TALL-1", Title: "t", Summary: "s", Status: quest.StatusActive, Gates: gates}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}

	m := NewModel(s, nil, Commands{})
	m.width = 120
	m, _ = update(m, key("l")) // enter the detail pane (focus the quest anchor)
	for i := 0; i < 12; i++ {
		m, _ = update(m, key("j")) // move to the last toggle gate
	}

	// A viewport too short to show every row at once.
	out := strip(m.renderDetail(70, 6))
	if !strings.Contains(out, "g11") {
		t.Errorf("focused row g11 scrolled out of the viewport:\n%s", out)
	}
}

func TestDetailFocusUsesSelectionBackground(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	s := newStore(t)
	q := &quest.Quest{ID: "Q-1", Title: "Q-1", Summary: "s", Status: quest.StatusActive,
		Gates: []quest.Gate{{Name: "ui-ok", Type: quest.GateToggle}}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 120, 40
	m, _ = update(m, key("l")) // focus the detail pane (quest anchor first)
	m, _ = update(m, key("j")) // move to the toggle gate

	out := m.renderDetail(70, 40)
	// The focused gate line carries the same selection background as a list row.
	wantBg := rowSelectedStyle.Render("ui-ok")
	bgSeq := wantBg[:strings.Index(wantBg, "ui-ok")] // the leading SGR (bg+fg)
	var focusedHasBg bool
	for _, ln := range strings.Split(out, "\n") {
		if strings.Contains(ansi.Strip(ln), "ui-ok") && strings.Contains(ln, bgSeq) {
			focusedHasBg = true
		}
	}
	if !focusedHasBg {
		t.Errorf("focused detail line is not painted with the selection background")
	}
}

func TestFocusedTextBlockHighlightsEveryWrappedLine(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Body: []quest.Block{
			{Type: quest.BlockHeading, Level: 2, Text: "Context"},
			{Type: quest.BlockText, Text: strings.Repeat("paragraph text wraps visibly ", 10)},
		},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 120, 40
	m, _ = update(m, key("l")) // quest target
	m, _ = update(m, key("j")) // heading
	m, _ = update(m, key("j")) // wrapped text block

	lines := strings.Split(m.renderDetail(70, 40), "\n")
	bgSeq := selectedBackgroundSeq(t)
	sel := detailSelectionForTest(t, m, 70)
	if len(sel.Lines) < 2 {
		t.Fatalf("setup selected %d lines, want wrapped text to select multiple lines", len(sel.Lines))
	}
	for line := range sel.Lines {
		if line >= len(lines) {
			t.Fatalf("selected line %d out of rendered range %d", line, len(lines))
		}
		if !strings.Contains(lines[line], bgSeq) {
			t.Fatalf("selected text line %d lacks selected background:\n%q", line, lines[line])
		}
	}
}

func TestFocusedListItemHighlightsOnlyThatItem(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	s := newStore(t)
	q := &quest.Quest{
		ID:      "Q-1",
		Title:   "Q-1",
		Summary: "s",
		Status:  quest.StatusActive,
		Body: []quest.Block{
			{Type: quest.BlockHeading, Level: 2, Text: "Approach"},
			{Type: quest.BlockList, Items: []string{
				"first list item wraps visibly across the detail pane with enough words",
				"second list item should also receive selected treatment",
			}},
		},
	}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})
	m.width, m.height = 120, 40
	m, _ = update(m, key("l")) // quest target
	m, _ = update(m, key("j")) // heading
	m, _ = update(m, key("j")) // first list item

	lines := strings.Split(m.renderDetail(70, 40), "\n")
	bgSeq := selectedBackgroundSeq(t)
	sel := detailSelectionForTest(t, m, 70)
	if len(sel.Lines) < 2 {
		t.Fatalf("setup selected %d lines, want wrapped first item to select multiple lines", len(sel.Lines))
	}
	for line := range sel.Lines {
		if line >= len(lines) {
			t.Fatalf("selected line %d out of rendered range %d", line, len(lines))
		}
		if !strings.Contains(lines[line], bgSeq) {
			t.Fatalf("selected list line %d lacks selected background:\n%q", line, lines[line])
		}
		if strings.Contains(ansi.Strip(lines[line]), "second list item") {
			t.Fatalf("first item focus selected second item line %d:\n%q", line, ansi.Strip(lines[line]))
		}
	}

	m, _ = update(m, key("j")) // second list item
	lines = strings.Split(m.renderDetail(70, 40), "\n")
	sel = detailSelectionForTest(t, m, 70)
	var sawSecond bool
	for line := range sel.Lines {
		if !strings.Contains(lines[line], bgSeq) {
			t.Fatalf("selected second-item line %d lacks selected background:\n%q", line, lines[line])
		}
		plain := ansi.Strip(lines[line])
		if strings.Contains(plain, "first list item") {
			t.Fatalf("second item focus selected first item line %d:\n%q", line, plain)
		}
		if strings.Contains(plain, "second list item") {
			sawSecond = true
		}
	}
	if !sawSecond {
		t.Fatalf("second item focus did not select the second item:\n%s", strings.Join(lines, "\n"))
	}
}

func selectedBackgroundSeq(t *testing.T) string {
	t.Helper()
	marker := rowSelectedStyle.Render("selected")
	idx := strings.Index(marker, "selected")
	if idx < 0 {
		t.Fatalf("could not find marker in selected style %q", marker)
	}
	return marker[:idx]
}

func detailSelectionForTest(t *testing.T, m Model, width int) quest.DetailLineSelection {
	t.Helper()
	q, ok := m.Selected()
	if !ok {
		t.Fatal("no selected quest")
	}
	inner := width - detailPadLeft - detailPadRight
	_, sel := quest.RenderDetailLineSelection(&q, m.runtimeOf(q.ID), inner, m.detailFocus())
	return sel
}

func TestSelectedListRowPreservesIDStyleAndSelectionBackground(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	s := newStore(t)
	q := &quest.Quest{ID: "ACT-1", Title: "Visible title", Summary: "s", Status: quest.StatusActive}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	m := NewModel(s, nil, Commands{})

	out := m.renderList(44, 20)
	titleLine, idLine := "", ""
	for _, ln := range strings.Split(out, "\n") {
		plain := ansi.Strip(ln)
		if strings.Contains(plain, "Visible title") {
			titleLine = ln
		}
		if strings.Contains(plain, "ACT-1") {
			idLine = ln
		}
	}
	if titleLine == "" || idLine == "" {
		t.Fatalf("selected row not found:\n%s", out)
	}

	bg := lipgloss.NewStyle().Background(palette.SelectedRowBg).Render("x")
	bgSeq := bg[:strings.Index(bg, "x")]
	id := lipgloss.NewStyle().Foreground(lipgloss.Color("#5a6577")).Bold(true).Render("ACT-1")
	idSeq := id[:strings.Index(id, "ACT-1")]
	if !strings.Contains(titleLine, bgSeq) || !strings.Contains(idLine, bgSeq) {
		t.Fatalf("selected two-line row missing selection background:\n%q\n%q", titleLine, idLine)
	}
	if !strings.Contains(idLine, idSeq) {
		t.Fatalf("selected row lost quest id styling/color: %q", idLine)
	}
}

func TestAutoResultsShowOnBoardDetail(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "ACT-1", Title: "t", Summary: "s", Status: quest.StatusActive,
		Gates: []quest.Gate{{Name: "tests", Type: quest.GateAuto, Check: "cmd:make test"}}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	runtimeFor := func(ids []string) map[string]quest.Runtime {
		return map[string]quest.Runtime{"ACT-1": {Gates: map[string]string{"tests": "fail"}}}
	}
	m := NewModel(s, runtimeFor, Commands{})
	m.width, m.height = 120, 40
	got := strip(m.renderDetail(70, 40))
	if !strings.Contains(got, "✗") {
		t.Errorf("board detail did not overlay the failing auto result:\n%s", got)
	}
}

func TestOpenAndEditDispatch(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)

	var opened, edited string
	openCmd := func(id string) tea.Cmd { return func() tea.Msg { opened = id; return nil } }
	editCmd := func(id string) tea.Cmd { return func() tea.Msg { edited = id; return nil } }
	m := NewModel(s, nil, Commands{Open: openCmd, Edit: editCmd})

	_, cmd := update(m, key("o"))
	if cmd == nil {
		t.Fatal("open produced no command")
	}
	cmd()
	if opened != "ACT-1" {
		t.Errorf("open dispatched for %q, want ACT-1", opened)
	}

	_, cmd = update(m, key("e"))
	if cmd == nil {
		t.Fatal("edit produced no command")
	}
	cmd()
	if edited != "ACT-1" {
		t.Errorf("edit dispatched for %q, want ACT-1", edited)
	}
}

// TestInitArmsPollTick asserts the board starts its monitor refresh: Init
// must schedule the first tick.
func TestInitArmsPollTick(t *testing.T) {
	s := newStore(t)
	m := NewModel(s, nil, Commands{})
	if m.Init() == nil {
		t.Fatal("Init returned no command; the board would never poll")
	}
}

// TestTickReloadsAndReschedules asserts a poll tick re-reads the store (an
// external change appears without keypresses) and arms the next tick.
func TestTickReloadsAndReschedules(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	m := NewModel(s, nil, Commands{})

	save(t, s, "ACT-2", quest.StatusActive) // external write between ticks
	m, cmd := update(m, tickMsg(time.Now()))
	if cmd == nil {
		t.Fatal("tick did not reschedule the next poll")
	}
	if got := ids(m.visible); len(got) != 2 {
		t.Fatalf("tick did not reload the store: visible = %v", got)
	}
}

// TestReloadKeepsSelectionIdentity asserts a reload moves the cursor WITH the
// selected quest when rows shift underneath it — a poll must not yank the
// user onto a different quest.
func TestReloadKeepsSelectionIdentity(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	save(t, s, "ACT-2", quest.StatusActive)

	m := NewModel(s, nil, Commands{})
	m, _ = update(m, key("j")) // cursor on ACT-2
	if sel, _ := m.Selected(); sel.ID != "ACT-2" {
		t.Fatalf("setup: cursor on %q, want ACT-2", sel.ID)
	}

	save(t, s, "ACT-0", quest.StatusActive) // sorts above, shifting rows down
	m, _ = update(m, tickMsg(time.Now()))
	if sel, _ := m.Selected(); sel.ID != "ACT-2" {
		t.Fatalf("after reload, selection = %q, want ACT-2 (identity-stable)", sel.ID)
	}
	if m.cursor != 2 {
		t.Fatalf("cursor = %d, want 2 (followed the quest down)", m.cursor)
	}
}

// TestReloadDropsDetailFocusWhenSelectionLeavesTab asserts the fallback: when
// the selected quest leaves the current tab between polls, the detail focus
// and scroll reset instead of pointing at a different quest's rows.
func TestReloadDropsDetailFocusWhenSelectionLeavesTab(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "ACT-1", Title: "t", Summary: "s", Status: quest.StatusActive,
		Gates: []quest.Gate{{Name: "ui", Type: quest.GateToggle}}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	save(t, s, "ACT-2", quest.StatusActive)

	m := NewModel(s, nil, Commands{})
	m, _ = update(m, key("l")) // focus ACT-1's detail pane
	if m.focus != focusDetail {
		t.Fatal("setup: detail pane not focused")
	}

	// ACT-1 is marked done externally (e.g. `qm quest done` in another pane).
	moved, _ := s.Load("ACT-1")
	if err := quest.SetStatus(moved, quest.StatusDone); err != nil {
		t.Fatalf("set status: %v", err)
	}
	if err := s.Save(moved); err != nil {
		t.Fatalf("save moved: %v", err)
	}

	m, _ = update(m, tickMsg(time.Now()))
	if m.focus != focusList {
		t.Errorf("focus should fall back to the list when the selection leaves the tab")
	}
	if m.detailScroll != 0 || m.detailCursor != 0 {
		t.Errorf("detail scroll/cursor should reset, got %d/%d", m.detailScroll, m.detailCursor)
	}
	if sel, ok := m.Selected(); !ok || sel.ID != "ACT-2" {
		t.Errorf("selection should clamp to a remaining row, got %v", sel.ID)
	}
}

// TestAdventurerActivityShowsOnBoardDetail asserts the monitor view: the detail
// pane shows what each attached session is doing.
func TestAdventurerActivityShowsOnBoardDetail(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	now := time.Now().UTC()
	runtimeFor := func(ids []string) map[string]quest.Runtime {
		return map[string]quest.Runtime{"ACT-1": {
			Sessions:    []string{"qm-a"},
			Adventurers: []quest.Adventurer{{ID: "qm-a", Agent: "claude", State: "working", Since: now.Add(-134 * time.Second)}},
			ObservedAt:  now,
		}}
	}
	m := NewModel(s, runtimeFor, Commands{})
	m.width, m.height = 120, 40

	detail := strip(m.renderDetail(80, 30))
	if !strings.Contains(detail, "⚔ 1 on it:") ||
		!strings.Contains(detail, "- 󰛄 qm-a · working 2m14s") {
		t.Fatalf("board detail missing live adventurer activity:\n%s", detail)
	}
}

func ids(qs []quest.Quest) []string {
	out := make([]string, len(qs))
	for i, q := range qs {
		out[i] = q.ID
	}
	return out
}
