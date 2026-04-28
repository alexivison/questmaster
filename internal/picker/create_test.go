package picker

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
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
		"longer prefix": {[]string{"legalon-next", "legalon-web"}, "legalon-"},
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

	f, _ := NewCreateForm(false, false, root+"/pack")
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
	root := makeDirs(t, "legalon-next", "legalon-web")

	f, _ := NewCreateForm(false, false, root+"/legalon")
	f.focus = fieldDir
	f.tabComplete()

	wantPrefix := root + "/legalon-"
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

	f, _ := NewCreateForm(false, false, root+"/a")
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

	f, _ := NewCreateForm(false, false, root+"/zzz")
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

	f, _ := NewCreateForm(false, false, root+"/src/")
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
		return "party-test", nil
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
		return "party-test", nil
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
		return "party-test", nil
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
		active: []Entry{{SessionID: "party-a", Title: "alpha"}},
		width:  100,
		height: 12,
	}

	view := m.View()
	if !strings.Contains(view, "m/N master") {
		t.Fatalf("footer should advertise m and N for master create, got %q", view)
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

	result, cmd := m.updateCreate(createResultMsg{sessionID: "party-new-123"})
	rm := result.(Model)
	if rm.selected != "party-new-123" {
		t.Errorf("selected: got %q, want %q", rm.selected, "party-new-123")
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

func TestEnterCreateMode_MasterOnTmuxTabUsesPartyForm(t *testing.T) {
	t.Parallel()
	m := Model{
		tab:  tabTmux,
		tmux: []Entry{{SessionID: "tmux-a"}},
		startFn: func(ctx context.Context, title, cwd string, opts CreateStartOptions) (string, error) {
			return "party-test", nil
		},
		tmuxStartFn: func(ctx context.Context, name, cwd string) (string, error) {
			return "tmux-test", nil
		},
		agentOpts: testAgentOptions(),
	}

	result, _ := m.enterCreateMode(true)
	rm := result.(Model)
	if rm.mode != modeCreate {
		t.Fatalf("expected modeCreate, got %d", rm.mode)
	}
	if rm.createForm.tmux {
		t.Fatal("master create on Tmux tab should use the party create form")
	}
	if !rm.createForm.master {
		t.Fatal("master create should preserve master flag")
	}
	if !rm.createForm.hasAgentSelectors() {
		t.Fatal("party create form should expose agent selectors")
	}
}

// ---------------------------------------------------------------------------
// CreateForm field focus tests
// ---------------------------------------------------------------------------

func TestCreateForm_TabSwitchesFocus(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, false, "/tmp")

	if f.focus != fieldTitle {
		t.Fatalf("initial focus should be title, got %d", f.focus)
	}

	// Tab on title → dir.
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyTab})
	if f.focus != fieldDir {
		t.Errorf("after tab: expected fieldDir, got %d", f.focus)
	}

	// Shift+Tab on dir → title.
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyShiftTab})
	if f.focus != fieldTitle {
		t.Errorf("after shift+tab: expected fieldTitle, got %d", f.focus)
	}
}

func TestCreateForm_InitialDir_PreFilled(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, false, "/home/user/project")

	got := f.dirInput.Value()
	if got != "/home/user/project" {
		t.Errorf("dir should be pre-filled: got %q", got)
	}
}

func TestCreateForm_MasterFlag(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(true, false, "")
	if !f.master {
		t.Error("master flag should be true")
	}
	f2, _ := NewCreateForm(false, false, "")
	if f2.master {
		t.Error("master flag should be false")
	}
}

func TestCreateForm_View_ShowsHeader(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, false, "/tmp")
	view := f.View(80, 24)
	if !strings.Contains(view, "New Session") {
		t.Error("view should contain 'New Session' header")
	}

	fm, _ := NewCreateForm(true, false, "/tmp")
	viewM := fm.View(80, 24)
	if !strings.Contains(viewM, "New Master Session") {
		t.Error("master view should contain 'New Master Session' header")
	}
}

func testAgentOptions() AgentOptions {
	return AgentOptions{
		Available:        []string{"claude", "codex"},
		DefaultPrimary:   "claude",
		DefaultCompanion: "codex",
	}
}

func TestCreateForm_AgentDefaults_RegularAndMaster(t *testing.T) {
	t.Parallel()

	f, _ := NewCreateForm(false, false, "/tmp", testAgentOptions())
	if got := f.selectedPrimary(); got != "claude" {
		t.Fatalf("regular primary default = %q, want claude", got)
	}
	if got := f.selectedCompanion(); got != "codex" {
		t.Fatalf("regular companion default = %q, want codex", got)
	}

	fm, _ := NewCreateForm(true, false, "/tmp", testAgentOptions())
	if got := fm.selectedPrimary(); got != "claude" {
		t.Fatalf("master primary default = %q, want claude", got)
	}
	if got := fm.selectedCompanion(); got != "" {
		t.Fatalf("master companion default = %q, want none", got)
	}
}

func TestCreateForm_View_ShowsAgentSelectors(t *testing.T) {
	t.Parallel()

	f, _ := NewCreateForm(false, false, "/tmp", testAgentOptions())
	view := f.View(80, 24)
	if !strings.Contains(view, "Primary:") {
		t.Fatal("view should contain Primary selector")
	}
	if !strings.Contains(view, "Companion:") {
		t.Fatal("view should contain Companion selector")
	}
}

func TestCreateForm_Master_HidesCompanionSelector(t *testing.T) {
	t.Parallel()

	f, _ := NewCreateForm(true, false, "/tmp", testAgentOptions())
	view := f.View(80, 24)
	if !strings.Contains(view, "Primary:") {
		t.Fatal("master view should still contain Primary selector")
	}
	if strings.Contains(view, "Companion:") {
		t.Fatal("master view must not render Companion selector")
	}
}

func TestCreateForm_Master_NavigationSkipsCompanion(t *testing.T) {
	t.Parallel()

	f, _ := NewCreateForm(true, false, "/tmp", testAgentOptions())
	// title → dir → primary; third down must clamp at primary since companion
	// is excluded from fieldOrder in master mode.
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})
	if f.focus != fieldPrimary {
		t.Fatalf("after two downs: expected primary, got %d", f.focus)
	}
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})
	if f.focus != fieldPrimary {
		t.Fatalf("third down must clamp at primary for master form, got %d", f.focus)
	}
}

// ---------------------------------------------------------------------------
// Enter/submit tests
// ---------------------------------------------------------------------------

func TestCreateForm_Enter_ValidDir_EmitsRequest(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	f, _ := NewCreateForm(false, false, dir)
	// Set title.
	f.titleInput.SetValue("my-session")
	// Move focus to dir (already pre-filled with valid dir).
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyTab})

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

func TestUpdateCreate_TmuxMasterRequestUsesPartyStart(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	startCalled := false
	tmuxCalled := false
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
			return "party-master-123", nil
		},
		tmuxStartFn: func(ctx context.Context, name, cwd string) (string, error) {
			tmuxCalled = true
			return "tmux-123", nil
		},
	}

	_, cmd := m.updateCreate(createRequestMsg{
		title: "master",
		dir:   dir,
		opts:  CreateStartOptions{Master: true},
		tmux:  true,
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
	if result.sessionID != "party-master-123" {
		t.Fatalf("sessionID = %q, want party-master-123", result.sessionID)
	}
	if !startCalled {
		t.Fatal("expected party start function to be called")
	}
	if tmuxCalled {
		t.Fatal("plain tmux start should not be called for master create")
	}
}

func TestCreateForm_Enter_MasterFlag(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	f, _ := NewCreateForm(true, false, dir)
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyTab}) // focus dir

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
	f, _ := NewCreateForm(false, false, dir, testAgentOptions())
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})  // dir
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})  // primary
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRight}) // primary: claude → codex
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})  // companion
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyLeft})  // companion: codex → claude

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected create command")
	}

	req := cmd().(createRequestMsg)
	if req.opts.Primary != "codex" {
		t.Fatalf("primary = %q, want codex", req.opts.Primary)
	}
	if req.opts.Companion != "claude" {
		t.Fatalf("companion = %q, want claude", req.opts.Companion)
	}
	if req.opts.NoCompanion {
		t.Fatal("expected companion to be enabled")
	}
	if req.opts.Master {
		t.Fatal("expected non-master request")
	}
}

func TestCreateForm_Master_Enter_EmitsNoCompanion(t *testing.T) {
	t.Parallel()

	dir := t.TempDir()
	f, _ := NewCreateForm(true, false, dir, testAgentOptions())
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown}) // dir
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown}) // primary

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected create command")
	}

	req := cmd().(createRequestMsg)
	if req.opts.Primary != "claude" {
		t.Fatalf("primary = %q, want claude", req.opts.Primary)
	}
	if req.opts.Companion != "" {
		t.Fatalf("companion = %q, want empty for master", req.opts.Companion)
	}
	if !req.opts.NoCompanion {
		t.Fatal("expected NoCompanion=true for master")
	}
	if !req.opts.Master {
		t.Fatal("expected master request")
	}
}

func TestCreateForm_Enter_InvalidDir_SetsError(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, false, "/nonexistent-path-xyz-123")
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
	f, _ := NewCreateForm(false, false, "")
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

	f, _ := NewCreateForm(false, false, filePath)
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
	f, _ := NewCreateForm(false, false, dir)
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
	f, _ := NewCreateForm(false, false, root+"/a")
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
