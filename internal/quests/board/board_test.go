package board

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

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

func update(m Model, msg tea.Msg) (Model, tea.Cmd) {
	next, cmd := m.Update(msg)
	return next.(Model), cmd
}

func TestGroupsFromStore(t *testing.T) {
	s := newStore(t)
	saveProj(t, s, "ALPHA-2", quest.StatusActive, "alpha")
	saveProj(t, s, "ALPHA-1", quest.StatusWIP, "alpha")
	saveProj(t, s, "ZED-1", quest.StatusActive, "zed")
	save(t, s, "LOOSE-1", quest.StatusActive) // no project → Unsorted

	m := NewModel(s, nil, Commands{})
	groups := m.Groups()
	if len(groups) != 3 {
		t.Fatalf("got %d groups, want 3 (alpha, zed, Unsorted)", len(groups))
	}
	// Project sections: alphabetical, Unsorted last.
	if groups[0].Label != "alpha" || groups[1].Label != "zed" || groups[2].Label != "Unsorted" {
		t.Fatalf("group order = %q/%q/%q, want alpha/zed/Unsorted",
			groups[0].Label, groups[1].Label, groups[2].Label)
	}
	// Within a project, rows are status-ordered: active (ALPHA-2) before wip (ALPHA-1).
	if got := ids(groups[0].Quests); len(got) != 2 || got[0] != "ALPHA-2" || got[1] != "ALPHA-1" {
		t.Fatalf("alpha rows = %v, want [ALPHA-2 ALPHA-1] (active before wip)", got)
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

	calls := 0
	runtimeFor := func(id string) quest.Runtime {
		calls++
		if id == "ACT-2" {
			return quest.Runtime{Sessions: []string{"qm-2"}}
		}
		return quest.Runtime{}
	}
	m := NewModel(s, runtimeFor, Commands{})
	if calls != 1 {
		t.Fatalf("initial runtime calls = %d, want 1", calls)
	}

	save(t, s, "ACT-2", quest.StatusActive)
	m, _ = update(m, key("r"))
	if calls != 3 {
		t.Fatalf("runtime calls after refresh = %d, want 3", calls)
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

func TestListRowsHaveVerticalPadding(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	m := NewModel(s, nil, Commands{})

	lines := strings.Split(strip(m.renderList(44, 20)), "\n")
	row := -1
	for i, ln := range lines {
		if strings.Contains(ln, "ACT-1") {
			row = i
			break
		}
	}
	if row <= 0 || row >= len(lines)-1 {
		t.Fatalf("could not find row with vertical padding:\n%s", strings.Join(lines, "\n"))
	}
	if strings.TrimSpace(lines[row-1]) != "" || strings.TrimSpace(lines[row+1]) != "" {
		t.Fatalf("quest row should have one blank line of vertical padding around it:\n%s", strings.Join(lines, "\n"))
	}
}

func TestAttachedIndicatorFromRuntimeScan(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive) // on it
	save(t, s, "ACT-2", quest.StatusActive) // waiting

	runtimeFor := func(id string) quest.Runtime {
		if id == "ACT-1" {
			return quest.Runtime{Sessions: []string{"qm-1"}}
		}
		return quest.Runtime{}
	}
	m := NewModel(s, runtimeFor, Commands{})
	list := strip(m.renderList(44, 20))

	// ACT-1 is attached (⚔); the idle active ACT-2 shows the ◆ status glyph.
	if !strings.Contains(list, "⚔") {
		t.Errorf("attached quest missing the on-it indicator:\n%s", list)
	}
	if !strings.Contains(list, "◆") {
		t.Errorf("idle active quest missing its status glyph:\n%s", list)
	}
}

func TestBoardDetailShowsRuntimeAgent(t *testing.T) {
	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	runtimeFor := func(id string) quest.Runtime {
		return quest.Runtime{Sessions: []string{"qm-1"}, Agent: "claude"}
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

	runtimeFor := func(id string) quest.Runtime {
		if id == "ACT-1" {
			return quest.Runtime{
				Sessions: []string{"qm-loop"},
				Loop:     &quest.LoopRuntime{SessionID: "qm-loop", Iterations: 3, LastVerdict: "fail"},
			}
		}
		return quest.Runtime{}
	}
	m := NewModel(s, runtimeFor, Commands{})
	m.width, m.height = 120, 40

	detail := strip(m.renderDetail(80, 30))
	t.Logf("board detail:\n%s", detail)
	if !strings.Contains(detail, "↻ loop i3 fail") {
		t.Fatalf("detail missing loop mode:\n%s", detail)
	}
	if !strings.Contains(detail, "qm-loop") {
		t.Fatalf("detail missing loop session:\n%s", detail)
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

	// a → board (active), d → done, w → back to draft (wip): any direction.
	steps := []struct {
		key  string
		want quest.Status
	}{
		{"a", quest.StatusActive},
		{"d", quest.StatusDone},
		{"a", quest.StatusActive}, // done → back to the board
		{"w", quest.StatusWIP},    // active → back to draft
		{"d", quest.StatusDone},   // wip → straight to done
	}
	for _, st := range steps {
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
	save(t, s, "WIP-1", quest.StatusWIP) // last row (active sorts before wip)

	m := NewModel(s, nil, Commands{})
	m, _ = update(m, key("j"))
	m, _ = update(m, key("j")) // cursor on the last row, WIP-1
	if sel, _ := m.Selected(); sel.ID != "WIP-1" {
		t.Fatalf("setup: cursor on %q, want WIP-1", sel.ID)
	}

	m, _ = update(m, key("x")) // delete immediately

	if s.Exists("WIP-1") {
		t.Errorf("deleted quest still present in the store")
	}
	if len(m.quests) != 2 {
		t.Fatalf("after delete, %d quests remain, want 2", len(m.quests))
	}
	if m.cursor < 0 || m.cursor >= len(m.quests) {
		t.Errorf("cursor %d out of bounds after delete (len %d)", m.cursor, len(m.quests))
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

	// Enter the detail pane; the only interactive target is the toggle gate
	// (the auto gate is skipped).
	m, _ = update(m, key("l"))
	tgt, ok := m.currentTarget()
	if !ok || tgt.Kind != quest.TargetGate {
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
	m, _ = update(m, key("j")) // move down two targets
	m, _ = update(m, key("j"))
	if tgt, _ := m.currentTarget(); tgt.Kind != quest.TargetRelated {
		t.Errorf("after two downs, focus should be on the related entry, got %+v", tgt)
	}
	m, _ = update(m, key("esc")) // leave
	if m.focus != focusList {
		t.Errorf("esc did not return to list focus")
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

	m, _ = update(m, key("l")) // detail focus → first related (no toggle gates here)
	m, _ = update(m, key("j")) // move to the second related entry
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
	m, _ = update(m, key("l")) // enter the detail pane (focus the first gate)
	for i := 0; i < 11; i++ {
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
	m, _ = update(m, key("l")) // focus the detail pane (the toggle gate)

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

func TestSelectedListRowPreservesIDStyleAndSelectionBackground(t *testing.T) {
	lipgloss.SetColorProfile(termenv.TrueColor)
	t.Cleanup(func() { lipgloss.SetColorProfile(termenv.Ascii) })

	s := newStore(t)
	save(t, s, "ACT-1", quest.StatusActive)
	m := NewModel(s, nil, Commands{})

	out := m.renderList(44, 20)
	selected := ""
	for _, ln := range strings.Split(out, "\n") {
		if strings.Contains(ansi.Strip(ln), "ACT-1") {
			selected = ln
			break
		}
	}
	if selected == "" {
		t.Fatalf("selected row not found:\n%s", out)
	}

	bg := lipgloss.NewStyle().Background(palette.SelectedRowBg).Render("x")
	bgSeq := bg[:strings.Index(bg, "x")]
	id := lipgloss.NewStyle().Foreground(lipgloss.Color("#e6b860")).Bold(true).Render("ACT-1")
	idSeq := id[:strings.Index(id, "ACT-1")]
	if !strings.Contains(selected, bgSeq) {
		t.Fatalf("selected row missing selection background: %q", selected)
	}
	if !strings.Contains(selected, idSeq) {
		t.Fatalf("selected row lost quest id styling/color: %q", selected)
	}
}

func TestAutoResultsShowOnBoardDetail(t *testing.T) {
	s := newStore(t)
	q := &quest.Quest{ID: "ACT-1", Title: "t", Summary: "s", Status: quest.StatusActive,
		Gates: []quest.Gate{{Name: "tests", Type: quest.GateAuto, Check: "cmd:make test"}}}
	if err := s.Save(q); err != nil {
		t.Fatalf("save: %v", err)
	}
	runtimeFor := func(id string) quest.Runtime {
		return quest.Runtime{Gates: map[string]string{"tests": "fail"}}
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

func ids(qs []quest.Quest) []string {
	out := make([]string, len(qs))
	for i, q := range qs {
		out[i] = q.ID
	}
	return out
}
