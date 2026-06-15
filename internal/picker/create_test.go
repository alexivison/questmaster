package picker

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
	"github.com/muesli/termenv"
)

// ---------------------------------------------------------------------------
// Helper: create temp directory tree for completion tests
// ---------------------------------------------------------------------------

// makeDirs creates subdirectories under root and returns root.
func makeDirs(t *testing.T, names ...string) string {
	t.Helper()
	root := t.TempDir()
	for _, n := range names {
		if err := os.MkdirAll(filepath.Join(root, n), 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", n, err)
		}
	}
	return root
}

// makeFile creates a regular file (not a directory) under root.
func makeFile(t *testing.T, root, name string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, name), []byte("x"), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
}

// ---------------------------------------------------------------------------
// splitDirPartial tests
// ---------------------------------------------------------------------------

func TestSplitDirPartial(t *testing.T) {
	t.Parallel()
	cases := map[string]struct {
		input              string
		wantParent, wantPt string
	}{
		"trailing slash":   {"/tmp/foo/", "/tmp/foo/", ""},
		"partial basename": {"/tmp/foo", "/tmp", "foo"},
		"root":             {"/", "/", ""},
		"empty":            {"", "", ""},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			p, pt := splitDirPartial(tc.input)
			if p != tc.wantParent || pt != tc.wantPt {
				t.Errorf("splitDirPartial(%q) = (%q, %q), want (%q, %q)", tc.input, p, pt, tc.wantParent, tc.wantPt)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// listDirMatches tests
// ---------------------------------------------------------------------------

func TestListDirMatches_FiltersCorrectly(t *testing.T) {
	t.Parallel()
	root := makeDirs(t, "apps", "api", "packages", "node_modules")
	makeFile(t, root, "README.md")

	cases := map[string]struct {
		prefix string
		want   []string
	}{
		"prefix a":     {"a", []string{"api", "apps"}},
		"prefix app":   {"app", []string{"apps"}},
		"prefix p":     {"p", []string{"packages"}},
		"prefix z":     {"z", nil},
		"empty prefix": {"", []string{"api", "apps", "node_modules", "packages"}},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got := listDirMatches(root, tc.prefix)
			if len(got) != len(tc.want) {
				t.Fatalf("listDirMatches(%q, %q) = %v, want %v", root, tc.prefix, got, tc.want)
			}
			for i, w := range tc.want {
				if got[i] != w {
					t.Errorf("index %d: got %q, want %q", i, got[i], w)
				}
			}
		})
	}
}

func TestListDirMatches_ExcludesFiles(t *testing.T) {
	t.Parallel()
	root := makeDirs(t, "src")
	makeFile(t, root, "src-file.txt")

	got := listDirMatches(root, "src")
	if len(got) != 1 || got[0] != "src" {
		t.Errorf("expected [src], got %v", got)
	}
}

func TestListDirMatches_InvalidParent(t *testing.T) {
	t.Parallel()
	got := listDirMatches("/nonexistent-path-xyz", "foo")
	if got != nil {
		t.Errorf("expected nil for invalid parent, got %v", got)
	}
}

// ---------------------------------------------------------------------------
// commonPrefix tests
// ---------------------------------------------------------------------------

func TestCommonPrefix(t *testing.T) {
	t.Parallel()
	cases := map[string]struct {
		input []string
		want  string
	}{
		"empty":         {nil, ""},
		"single":        {[]string{"hello"}, "hello"},
		"common":        {[]string{"apps", "api"}, "ap"},
		"full match":    {[]string{"test", "test"}, "test"},
		"no common":     {[]string{"abc", "xyz"}, ""},
		"longer prefix": {[]string{"project-next", "project-web"}, "project-"},
		"three strings": {[]string{"foobar", "foobaz", "foooo"}, "foo"},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got := commonPrefix(tc.input)
			if got != tc.want {
				t.Errorf("commonPrefix(%v) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// expandTilde tests
// ---------------------------------------------------------------------------

func TestExpandTilde(t *testing.T) {
	t.Parallel()
	home, _ := os.UserHomeDir()
	if home == "" {
		t.Skip("no home directory")
	}

	cases := map[string]struct {
		input, want string
	}{
		"tilde slash": {"~/Code", home + "/Code"},
		"tilde only":  {"~", home},
		"absolute":    {"/tmp/foo", "/tmp/foo"},
		"relative":    {"foo/bar", "foo/bar"},
		"empty":       {"", ""},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got := expandTilde(tc.input)
			if got != tc.want {
				t.Errorf("expandTilde(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// tabComplete integration tests
// ---------------------------------------------------------------------------

func TestTabComplete_SingleMatch(t *testing.T) {
	t.Parallel()
	root := makeDirs(t, "packages")

	f, _ := NewCreateForm(false, root+"/pack")
	f.focus = fieldDir
	f.tabComplete()

	want := root + "/packages/"
	got := f.dirInput.Value()
	if got != want {
		t.Errorf("single match: got %q, want %q", got, want)
	}
	if f.completions != nil {
		t.Error("single match should clear completions")
	}
}

func TestTabComplete_MultipleMatches_CommonPrefix(t *testing.T) {
	t.Parallel()
	root := makeDirs(t, "project-next", "project-web")

	f, _ := NewCreateForm(false, root+"/project")
	f.focus = fieldDir
	f.tabComplete()

	wantPrefix := root + "/project-"
	got := f.dirInput.Value()
	if got != wantPrefix {
		t.Errorf("common prefix: got %q, want %q", got, wantPrefix)
	}
	if len(f.completions) != 2 {
		t.Fatalf("expected 2 completions, got %d", len(f.completions))
	}
}

func TestTabComplete_MultipleMatches_Cycling(t *testing.T) {
	t.Parallel()
	root := makeDirs(t, "apps", "api")

	f, _ := NewCreateForm(false, root+"/a")
	f.focus = fieldDir

	// First tab: fills common prefix "a" (already typed), stores completions.
	f.tabComplete()
	if len(f.completions) != 2 {
		t.Fatalf("expected 2 completions after first tab, got %d", len(f.completions))
	}

	// Second tab: cycle to first match.
	f.tabComplete()
	got := f.dirInput.Value()
	if !strings.HasSuffix(got, "api/") {
		t.Errorf("first cycle: got %q, want suffix api/", got)
	}

	// Third tab: cycle to second match.
	f.tabComplete()
	got = f.dirInput.Value()
	if !strings.HasSuffix(got, "apps/") {
		t.Errorf("second cycle: got %q, want suffix apps/", got)
	}

	// Fourth tab: wraps back.
	f.tabComplete()
	got = f.dirInput.Value()
	if !strings.HasSuffix(got, "api/") {
		t.Errorf("wrap cycle: got %q, want suffix api/", got)
	}
}

func TestTabComplete_NoMatches(t *testing.T) {
	t.Parallel()
	root := makeDirs(t, "src")

	f, _ := NewCreateForm(false, root+"/zzz")
	f.focus = fieldDir
	original := f.dirInput.Value()
	f.tabComplete()

	if f.dirInput.Value() != original {
		t.Errorf("no match should not change input: got %q, was %q", f.dirInput.Value(), original)
	}
}

func TestTabComplete_TrailingSlash_ListsContents(t *testing.T) {
	t.Parallel()
	root := makeDirs(t, "src/components", "src/utils")

	f, _ := NewCreateForm(false, root+"/src/")
	f.focus = fieldDir
	f.tabComplete()

	// Should have matches for directories inside src/
	if len(f.completions) != 2 {
		t.Fatalf("expected 2 completions for dir listing, got %d: %v", len(f.completions), f.completions)
	}
}

// ---------------------------------------------------------------------------
// Mode transition tests
// ---------------------------------------------------------------------------

func TestPickerKey_N_EntersCreateMode(t *testing.T) {
	t.Parallel()
	startFn := func(ctx context.Context, title, cwd string, opts CreateStartOptions) (string, error) {
		return "qm-test", nil
	}
	m := Model{
		active:  []Entry{{SessionID: "a"}},
		startFn: startFn,
	}

	msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'n'}}
	result, _ := m.handleKey(msg)
	rm := result.(Model)
	if rm.mode != modeCreate {
		t.Errorf("expected modeCreate, got %d", rm.mode)
	}
	if rm.createForm.master {
		t.Error("lowercase n should create non-master form")
	}
}

func TestPickerKey_M_EntersMasterCreateMode(t *testing.T) {
	t.Parallel()
	startFn := func(ctx context.Context, title, cwd string, opts CreateStartOptions) (string, error) {
		return "qm-test", nil
	}
	m := Model{
		active:  []Entry{{SessionID: "a"}},
		startFn: startFn,
	}

	msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'m'}}
	result, _ := m.handleKey(msg)
	rm := result.(Model)
	if rm.mode != modeCreate {
		t.Errorf("expected modeCreate, got %d", rm.mode)
	}
	if !rm.createForm.master {
		t.Error("lowercase m should create master form")
	}
}

func TestPickerKey_ShiftN_EntersMasterCreateMode(t *testing.T) {
	t.Parallel()
	startFn := func(ctx context.Context, title, cwd string, opts CreateStartOptions) (string, error) {
		return "qm-test", nil
	}
	m := Model{
		active:  []Entry{{SessionID: "a"}},
		startFn: startFn,
	}

	msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'N'}}
	result, _ := m.handleKey(msg)
	rm := result.(Model)
	if rm.mode != modeCreate {
		t.Errorf("expected modeCreate, got %d", rm.mode)
	}
	if !rm.createForm.master {
		t.Error("uppercase N should create master form")
	}
}

func TestPickerView_FooterShowsMasterAlias(t *testing.T) {
	t.Parallel()
	m := Model{
		active: []Entry{{SessionID: "qm-a", Title: "alpha"}},
		width:  100,
		height: 12,
	}

	view := m.View()
	if !strings.Contains(view, "m/N master") {
		t.Fatalf("footer should advertise m and N for master create, got %q", view)
	}
	if strings.Contains(view, "1-9") || strings.Contains(view, "jump") {
		t.Fatalf("footer should not advertise number shortcuts, got %q", view)
	}
}

func TestPickerKey_N_NoOpWithoutStartFn(t *testing.T) {
	t.Parallel()
	m := Model{
		active: []Entry{{SessionID: "a"}},
	}

	msg := tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'n'}}
	result, _ := m.handleKey(msg)
	rm := result.(Model)
	if rm.mode != modePicker {
		t.Errorf("n without startFn should stay in picker mode, got %d", rm.mode)
	}
}

func TestCreateForm_Esc_ReturnsToPicker(t *testing.T) {
	t.Parallel()
	m := Model{
		mode:    modeCreate,
		active:  []Entry{{SessionID: "a"}},
		startFn: func(ctx context.Context, title, cwd string, opts CreateStartOptions) (string, error) { return "", nil },
	}

	result, _ := m.updateCreate(createCancelMsg{})
	rm := result.(Model)
	if rm.mode != modePicker {
		t.Errorf("esc should return to picker mode, got %d", rm.mode)
	}
}

func TestCreateForm_Result_SetsSelected(t *testing.T) {
	t.Parallel()
	m := Model{mode: modeCreate}

	result, cmd := m.updateCreate(createResultMsg{sessionID: "qm-new-123"})
	rm := result.(Model)
	if rm.selected != "qm-new-123" {
		t.Errorf("selected: got %q, want %q", rm.selected, "qm-new-123")
	}
	// Should quit.
	if cmd == nil {
		t.Error("expected quit command")
	}
}

func TestCreateForm_ResultError_SetsErr(t *testing.T) {
	t.Parallel()
	m := Model{mode: modeCreate}

	result, _ := m.updateCreate(createResultMsg{err: os.ErrPermission})
	rm := result.(Model)
	if rm.createForm.err == "" {
		t.Error("expected error to be set on form")
	}
}

func TestEnterCreateMode_MasterUsesQuestmasterForm(t *testing.T) {
	t.Parallel()
	m := Model{
		startFn: func(ctx context.Context, title, cwd string, opts CreateStartOptions) (string, error) {
			return "qm-test", nil
		},
		agentOpts: testAgentOptions(),
	}

	result, _ := m.enterCreateMode(true)
	rm := result.(Model)
	if rm.mode != modeCreate {
		t.Fatalf("expected modeCreate, got %d", rm.mode)
	}
	if !rm.createForm.master {
		t.Fatal("master create should preserve master flag")
	}
	if !rm.createForm.hasAgentSelectors() {
		t.Fatal("session create form should expose agent selectors")
	}
}

func TestEnterCreateMode_PathStartsBlankAndFocused(t *testing.T) {
	t.Parallel()
	m := Model{
		startFn: func(ctx context.Context, title, cwd string, opts CreateStartOptions) (string, error) {
			return "qm-test", nil
		},
	}

	result, _ := m.enterCreateMode(false)
	rm := result.(Model)
	if rm.mode != modeCreate {
		t.Fatalf("expected modeCreate, got %d", rm.mode)
	}
	if rm.createForm.focus != fieldDir {
		t.Fatalf("initial create focus = %d, want fieldDir", rm.createForm.focus)
	}
	if got := rm.createForm.dirInput.Value(); got != "" {
		t.Fatalf("create-mode path should start blank, got %q", got)
	}
	fields := rm.createForm.fieldOrder()
	if len(fields) < 2 || fields[0] != fieldDir || fields[1] != fieldTitle {
		t.Fatalf("create-mode field order = %v, want dir then title", fields)
	}
}

// ---------------------------------------------------------------------------
// CreateForm field focus tests
// ---------------------------------------------------------------------------

func TestCreateForm_TabSwitchesFocus(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, "/tmp")

	if f.focus != fieldDir {
		t.Fatalf("initial focus should be dir, got %d", f.focus)
	}

	// Shift+Tab on dir clamps at the first field.
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyShiftTab})
	if f.focus != fieldDir {
		t.Errorf("after shift+tab: expected fieldDir, got %d", f.focus)
	}

	// Move forward through the field order.
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})
	if f.focus != fieldTitle {
		t.Errorf("after down: expected fieldTitle, got %d", f.focus)
	}
}

func TestCreateForm_FieldOrderStartsWithDirThenTitle(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, "")

	fields := f.fieldOrder()
	if len(fields) < 2 {
		t.Fatalf("fieldOrder = %v, want at least dir and title", fields)
	}
	if fields[0] != fieldDir || fields[1] != fieldTitle {
		t.Fatalf("fieldOrder starts %v, want [%d %d]", fields[:2], fieldDir, fieldTitle)
	}
	if f.focus != fieldDir {
		t.Fatalf("initial focus = %d, want fieldDir", f.focus)
	}
	if got := f.dirInput.Value(); got != "" {
		t.Fatalf("dir should start blank, got %q", got)
	}
}

func TestCreateForm_ViewShowsPathAboveTitle(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, "")

	view := ansi.Strip(f.View(80, 24))
	pathIndex := strings.Index(view, "Path:")
	titleIndex := strings.Index(view, "Title:")
	if pathIndex < 0 {
		t.Fatalf("view should contain Path label, got:\n%s", view)
	}
	if titleIndex < 0 {
		t.Fatalf("view should contain Title label, got:\n%s", view)
	}
	if pathIndex > titleIndex {
		t.Fatalf("Path field should render above Title field, got:\n%s", view)
	}
}

func TestCreateForm_MasterFlag(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(true, "")
	if !f.master {
		t.Error("master flag should be true")
	}
	f2, _ := NewCreateForm(false, "")
	if f2.master {
		t.Error("master flag should be false")
	}
}

func TestCreateForm_View_ShowsHeader(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, "/tmp")
	view := f.View(80, 24)
	if !strings.Contains(view, "New Session") {
		t.Error("view should contain 'New Session' header")
	}

	fm, _ := NewCreateForm(true, "/tmp")
	viewM := fm.View(80, 24)
	if !strings.Contains(viewM, "New Master Session") {
		t.Error("master view should contain 'New Master Session' header")
	}
}

func testAgentOptions() AgentOptions {
	return AgentOptions{
		Available:      []string{"claude", "codex"},
		DefaultPrimary: "claude",
	}
}

func TestCreateForm_AgentDefaults_RegularAndMaster(t *testing.T) {
	t.Parallel()

	f, _ := NewCreateForm(false, "/tmp", testAgentOptions())
	if got := f.selectedPrimary(); got != "claude" {
		t.Fatalf("regular primary default = %q, want claude", got)
	}

	fm, _ := NewCreateForm(true, "/tmp", testAgentOptions())
	if got := fm.selectedPrimary(); got != "claude" {
		t.Fatalf("master primary default = %q, want claude", got)
	}
}

func TestCreateForm_View_ShowsAgentSelectors(t *testing.T) {
	t.Parallel()

	f, _ := NewCreateForm(false, "/tmp", testAgentOptions())
	view := f.View(80, 24)
	if !strings.Contains(view, "Agent:") {
		t.Fatal("view should contain Agent selector")
	}
	if strings.Contains(view, "Primary:") {
		t.Fatal("view should not contain old Primary selector label")
	}
}

func TestCreateForm_View_ShowsNoColorOptionByDefault(t *testing.T) {
	lipgloss.SetColorProfile(termenv.ANSI)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(termenv.Ascii)
	})

	f, _ := NewCreateForm(false, "/tmp")
	view := f.View(80, 24)
	if !strings.Contains(view, "Color:") {
		t.Fatalf("questmaster create form should contain Color selector, got:\n%s", view)
	}
	if !strings.Contains(ansi.Strip(view), "[ none ]") {
		t.Fatalf("default color should be the no-color option, got:\n%s", view)
	}
	if strings.Contains(ansi.Strip(view), "[ ■ blue ]") {
		t.Fatalf("default color should not force blue, got:\n%s", view)
	}
}

func TestCreateForm_View_ShowsNamedColorWithSwatch(t *testing.T) {
	lipgloss.SetColorProfile(termenv.ANSI)
	t.Cleanup(func() {
		lipgloss.SetColorProfile(termenv.Ascii)
	})

	f, _ := NewCreateForm(false, "/tmp")
	f.setFocus(fieldColor)
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRight}) // none -> blue

	view := f.View(80, 24)
	if !strings.Contains(ansi.Strip(view), "[ ■ blue ]") {
		t.Fatalf("selected named color should render as a swatch plus name, got:\n%s", view)
	}
	wantSwatch := renderANSI(lipgloss.NewStyle().Foreground(lipgloss.Color("4")), "■")
	if !strings.Contains(view, wantSwatch) {
		t.Fatalf("blue color swatch should use actual blue foreground\nwant %q\ngot:\n%s", wantSwatch, view)
	}
}

func TestCreateForm_ArrowAndCtrlKeysMoveBetweenFields(t *testing.T) {
	t.Parallel()

	f, _ := NewCreateForm(true, "/tmp", testAgentOptions())
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})
	if f.focus != fieldTitle {
		t.Fatalf("after one down: expected title, got %d", f.focus)
	}
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})
	if f.focus != fieldPrimary {
		t.Fatalf("second down must land on primary, got %d", f.focus)
	}
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})
	if f.focus != fieldColor {
		t.Fatalf("third down must land on color, got %d", f.focus)
	}
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})
	if f.focus != fieldPrompt {
		t.Fatalf("fourth down must land on prompt, got %d", f.focus)
	}
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})
	if f.focus != fieldPrompt {
		t.Fatalf("fifth down must clamp at prompt, got %d", f.focus)
	}
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyCtrlK})
	if f.focus != fieldColor {
		t.Fatalf("ctrl+k must move back to color, got %d", f.focus)
	}
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyCtrlJ})
	if f.focus != fieldPrompt {
		t.Fatalf("ctrl+j must move forward to prompt, got %d", f.focus)
	}
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyUp})
	if f.focus != fieldColor {
		t.Fatalf("up must move back to color, got %d", f.focus)
	}
}

func TestCreateForm_PlainJKDoNotNavigateFields(t *testing.T) {
	t.Parallel()

	f, _ := NewCreateForm(false, "/tmp", testAgentOptions())
	f.setFocus(fieldTitle)
	f.titleInput.SetValue("")

	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if f.focus != fieldTitle {
		t.Fatalf("plain j should not move focus from title, got %d", f.focus)
	}
	if got := f.titleInput.Value(); got != "j" {
		t.Fatalf("plain j should be text input content, got %q", got)
	}

	f.setFocus(fieldPrimary)
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'j'}})
	if f.focus != fieldPrimary {
		t.Fatalf("plain j should not move focus from selector, got %d", f.focus)
	}
}

func TestCreateForm_ChoiceSelectorsSupportHL(t *testing.T) {
	t.Parallel()

	f, _ := NewCreateForm(false, "/tmp", testAgentOptions())
	f.setFocus(fieldPrimary)
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'l'}})
	if got := f.selectedPrimary(); got != "codex" {
		t.Fatalf("agent selector after l = %q, want codex", got)
	}
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'h'}})
	if got := f.selectedPrimary(); got != "claude" {
		t.Fatalf("agent selector after h = %q, want claude", got)
	}

	f.setFocus(fieldColor)
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'l'}})
	if got := f.selectedColor(); got != "blue" {
		t.Fatalf("color selector after l = %q, want blue", got)
	}
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'h'}})
	if got := f.selectedColor(); got != "" {
		t.Fatalf("color selector after h = %q, want no color", got)
	}
}

// ---------------------------------------------------------------------------
// Enter/submit tests
// ---------------------------------------------------------------------------

func TestCreateForm_Enter_ValidDir_EmitsRequest(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	f, _ := NewCreateForm(false, dir)
	// Set title.
	f.titleInput.SetValue("my-session")

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected a command from valid enter")
	}
	msg := cmd()
	req, ok := msg.(createRequestMsg)
	if !ok {
		t.Fatalf("expected createRequestMsg, got %T", msg)
	}
	if req.title != "my-session" {
		t.Errorf("title: got %q, want %q", req.title, "my-session")
	}
	if req.dir != dir {
		t.Errorf("dir: got %q, want %q", req.dir, dir)
	}
	if req.opts.Master {
		t.Error("expected master=false")
	}
}

func TestCreateForm_QuestSelection(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	f, _ := NewCreateForm(false, dir, testAgentOptions())
	f.initQuestOptions([]QuestChoice{
		{ID: "DEMO-1", Title: "Widget shell"},
		{ID: "DEMO-2", Title: "Settings catalog"},
	})
	if !f.hasQuestSelector() {
		t.Fatal("expected a quest selector")
	}
	// Default is "none".
	if f.selectedQuestID() != "" {
		t.Errorf("default quest = %q, want none", f.selectedQuestID())
	}

	// Focus the quest field and cycle right once → first active quest.
	f.setFocus(fieldQuest)
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRight})
	if f.selectedQuestID() != "DEMO-1" {
		t.Fatalf("after one right, quest = %q, want DEMO-1", f.selectedQuestID())
	}

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected a submit command")
	}
	req, ok := cmd().(createRequestMsg)
	if !ok {
		t.Fatalf("expected createRequestMsg, got %T", cmd())
	}
	if req.opts.QuestID != "DEMO-1" {
		t.Errorf("submitted QuestID = %q, want DEMO-1", req.opts.QuestID)
	}
}

func TestCreateForm_NoQuestsNoSelector(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, t.TempDir(), testAgentOptions())
	f.initQuestOptions(nil)
	if f.hasQuestSelector() {
		t.Error("no active quests should mean no quest selector")
	}
	for _, field := range f.fieldOrder() {
		if field == fieldQuest {
			t.Error("fieldQuest should not appear in fieldOrder when there are no quests")
		}
	}
}

func TestCreateForm_Enter_CapturesPrompt(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	f, _ := NewCreateForm(false, dir, testAgentOptions())
	f.titleInput.SetValue("with-prompt")
	f.promptInput.SetValue("  fix the failing test  ")

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected a command from valid enter")
	}
	req, ok := cmd().(createRequestMsg)
	if !ok {
		t.Fatalf("expected createRequestMsg, got %T", cmd())
	}
	if req.opts.Prompt != "fix the failing test" {
		t.Errorf("prompt: got %q, want %q (whitespace must be trimmed)", req.opts.Prompt, "fix the failing test")
	}
}

func TestCreateForm_Enter_EmitsSelectedColor(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	f, _ := NewCreateForm(false, dir)
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})  // title
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})  // color
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRight}) // none -> blue
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRight}) // blue -> green

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected a command from valid enter")
	}
	req, ok := cmd().(createRequestMsg)
	if !ok {
		t.Fatalf("expected createRequestMsg, got %T", cmd())
	}
	if req.opts.DisplayColor != "green" {
		t.Fatalf("display color = %q, want green", req.opts.DisplayColor)
	}
}

func TestCreateForm_Enter_DefaultNoColorLeavesDisplayColorEmpty(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	f, _ := NewCreateForm(false, dir)

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected a command from valid enter")
	}
	req, ok := cmd().(createRequestMsg)
	if !ok {
		t.Fatalf("expected createRequestMsg, got %T", cmd())
	}
	if req.opts.DisplayColor != "" {
		t.Fatalf("default display color = %q, want empty no-color selection", req.opts.DisplayColor)
	}
}

func TestCreateForm_PromptEnterInsertsNewline(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	f, _ := NewCreateForm(false, dir, testAgentOptions())
	f.promptInput.SetValue("first")
	f.setFocus(fieldPrompt)

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if f.submitting {
		t.Fatal("enter in prompt field must not submit")
	}
	if msg := commandMsg(cmd); msg != nil {
		if _, ok := msg.(createRequestMsg); ok {
			t.Fatal("enter in prompt field emitted createRequestMsg")
		}
	}
	if got := f.promptInput.Value(); got != "first\n" {
		t.Fatalf("prompt after enter = %q, want %q", got, "first\n")
	}
}

func TestCreateForm_CtrlSFromPromptCapturesMultilinePrompt(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	f, _ := NewCreateForm(false, dir, testAgentOptions())
	f.titleInput.SetValue("with-multiline-prompt")
	f.promptInput.SetValue("  first line\nsecond line  ")
	f.setFocus(fieldPrompt)

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyCtrlS})
	if !f.submitting {
		t.Fatal("ctrl+s in prompt field should submit")
	}
	if cmd == nil {
		t.Fatal("expected a command from ctrl+s")
	}
	req, ok := cmd().(createRequestMsg)
	if !ok {
		t.Fatalf("expected createRequestMsg, got %T", cmd())
	}
	if req.opts.Prompt != "first line\nsecond line" {
		t.Errorf("prompt: got %q, want multiline prompt with only outer whitespace trimmed", req.opts.Prompt)
	}
}

func TestCreateForm_PromptFooterShowsMultilineKeys(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, t.TempDir(), testAgentOptions())
	f.setFocus(fieldPrompt)

	view := f.View(100, 24)
	if !strings.Contains(view, "^s create") || !strings.Contains(view, "⏎ newline") || !strings.Contains(view, "^j/^k/↑↓ field") {
		t.Fatalf("prompt footer should advertise multiline prompt keys, got:\n%s", view)
	}
}

func TestPromptRowsClampsToAvailableHeight(t *testing.T) {
	t.Parallel()
	if got := promptRows(9, 7); got != 1 {
		t.Fatalf("promptRows should keep at least one row when space is tight, got %d", got)
	}
	if got := promptRows(24, 7); got != promptInputRows {
		t.Fatalf("promptRows should use default rows when space allows, got %d", got)
	}
}

func commandMsg(cmd tea.Cmd) tea.Msg {
	if cmd == nil {
		return nil
	}
	return cmd()
}

func TestUpdateCreate_RequestUsesQuestmasterStart(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	startCalled := false
	m := Model{
		mode: modeCreate,
		startFn: func(ctx context.Context, title, cwd string, opts CreateStartOptions) (string, error) {
			startCalled = true
			if title != "master" {
				t.Fatalf("title = %q, want master", title)
			}
			if cwd != dir {
				t.Fatalf("cwd = %q, want %q", cwd, dir)
			}
			if !opts.Master {
				t.Fatal("expected master start options")
			}
			return "qm-master-123", nil
		},
	}

	_, cmd := m.updateCreate(createRequestMsg{
		title: "master",
		dir:   dir,
		opts:  CreateStartOptions{Master: true},
	})
	if cmd == nil {
		t.Fatal("expected create command")
	}

	msg := cmd()
	result, ok := msg.(createResultMsg)
	if !ok {
		t.Fatalf("expected createResultMsg, got %T", msg)
	}
	if result.err != nil {
		t.Fatalf("create result error: %v", result.err)
	}
	if result.sessionID != "qm-master-123" {
		t.Fatalf("sessionID = %q, want qm-master-123", result.sessionID)
	}
	if !startCalled {
		t.Fatal("expected questmaster start function to be called")
	}
}

func TestCreateForm_Enter_MasterFlag(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	f, _ := NewCreateForm(true, dir)

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected command")
	}
	req := cmd().(createRequestMsg)
	if !req.opts.Master {
		t.Error("expected master=true for master form")
	}
}

func TestCreateForm_Enter_EmitsSelectedAgents(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	f, _ := NewCreateForm(false, dir, testAgentOptions())
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})  // title
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})  // primary
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRight}) // primary: claude → codex

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected create command")
	}

	req := cmd().(createRequestMsg)
	if req.opts.Primary != "codex" {
		t.Fatalf("primary = %q, want codex", req.opts.Primary)
	}
	if req.opts.Master {
		t.Fatal("expected non-master request")
	}
}

func TestCreateForm_Master_Enter_EmitsSelectedPrimary(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	f, _ := NewCreateForm(true, dir, testAgentOptions())
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown}) // title
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown}) // primary

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected create command")
	}

	req := cmd().(createRequestMsg)
	if req.opts.Primary != "claude" {
		t.Fatalf("primary = %q, want claude", req.opts.Primary)
	}
	if !req.opts.Master {
		t.Fatal("expected master request")
	}
}

func TestCreateForm_Enter_InvalidDir_SetsError(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, "/nonexistent-path-xyz-123")
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyTab}) // focus dir

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd != nil {
		t.Error("expected nil command for invalid directory")
	}
	if f.err == "" {
		t.Error("expected error message for invalid directory")
	}
}

func TestCreateForm_Enter_EmptyDir_SetsError(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, "")
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyTab}) // focus dir

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd != nil {
		t.Error("expected nil command for empty directory")
	}
	if f.err == "" {
		t.Error("expected error message for empty directory")
	}
}

func TestCreateForm_Enter_FileNotDir_SetsError(t *testing.T) {
	t.Parallel()
	root := t.TempDir()
	filePath := filepath.Join(root, "not-a-dir.txt")
	os.WriteFile(filePath, []byte("x"), 0o644)

	f, _ := NewCreateForm(false, filePath)
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyTab}) // focus dir

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd != nil {
		t.Error("expected nil command for file (not dir)")
	}
	if f.err == "" {
		t.Error("expected error when path is a file, not a directory")
	}
}

func TestCreateForm_SubmittingBlocksAllInput(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	f, _ := NewCreateForm(false, dir)
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyTab}) // focus dir

	// Enter sets submitting.
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if !f.submitting {
		t.Fatal("expected submitting=true after enter")
	}

	// All keys blocked while submitting (prevents stranding detached sessions).
	for _, key := range []tea.KeyMsg{
		{Type: tea.KeyEscape},
		{Type: tea.KeyCtrlC},
		{Type: tea.KeyCtrlS},
		{Type: tea.KeyEnter},
		{Type: tea.KeyRunes, Runes: []rune{'x'}},
	} {
		f, cmd := f.handleKey(key)
		if cmd != nil {
			t.Errorf("key %q should be no-op while submitting", key.String())
		}
		if !f.submitting {
			t.Errorf("submitting should remain true after %q", key.String())
		}
	}
}

func TestCreateForm_SubmittingClearedOnError(t *testing.T) {
	t.Parallel()
	m := Model{mode: modeCreate}
	m.createForm.submitting = true

	result, _ := m.updateCreate(createResultMsg{err: os.ErrPermission})
	rm := result.(Model)
	if rm.createForm.submitting {
		t.Error("submitting should be cleared on error")
	}
}

func TestCreateForm_CompletionsClearedOnNonTabKey(t *testing.T) {
	t.Parallel()
	root := makeDirs(t, "apps", "api")
	f, _ := NewCreateForm(false, root+"/a")
	f.focus = fieldDir

	// Trigger completions.
	f.tabComplete()
	if len(f.completions) == 0 {
		t.Fatal("expected completions to be set")
	}

	// Any non-tab key should clear them.
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'x'}})
	if f.completions != nil {
		t.Error("completions should be cleared after non-tab key")
	}
}
