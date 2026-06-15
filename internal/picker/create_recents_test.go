package picker

import (
	"errors"
	"reflect"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func recentsForm(t *testing.T, initialDir string, dirs []string) CreateForm {
	t.Helper()
	f, _ := NewCreateForm(false, initialDir)
	f.titleInput.Blur()
	f.focus = fieldDir
	f.dirInput.Focus()
	f.recentDirs = dirs
	return f
}

func typeRunes(f CreateForm, s string) CreateForm {
	for _, r := range s {
		f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
	}
	return f
}

func TestDirList_OpenFilterAccept(t *testing.T) {
	dirs := []string{"/work/questmaster", "/work/quotes", "/tmp/scratch"}
	f := recentsForm(t, "", dirs)

	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyCtrlR})
	if !f.dirListOpen {
		t.Fatal("ctrl+r should open the recents browser")
	}
	if len(f.dirMatches) != 3 {
		t.Fatalf("empty filter should show all recents, got %v", f.dirMatches)
	}

	f = typeRunes(f, "qm")
	if len(f.dirMatches) != 1 || f.dirMatches[0] != "/work/questmaster" {
		t.Fatalf("filter 'qm' = %v, want [/work/questmaster]", f.dirMatches)
	}

	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if f.dirListOpen {
		t.Fatal("enter should close the browser")
	}
	if got := f.dirInput.Value(); got != "/work/questmaster" {
		t.Fatalf("accepted dir = %q, want /work/questmaster", got)
	}
}

func TestDirList_EscKeepsTypedValue(t *testing.T) {
	f := recentsForm(t, "/initial/path", []string{"/work/questmaster"})

	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyCtrlR})
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyEsc})
	if f.dirListOpen {
		t.Fatal("esc should close the browser")
	}
	if got := f.dirInput.Value(); got != "/initial/path" {
		t.Fatalf("esc changed the input: got %q", got)
	}
}

func TestDirList_TabAcceptsAndAdvances(t *testing.T) {
	f := recentsForm(t, "", []string{"/work/questmaster"})

	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyCtrlR})
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyTab})
	if f.dirListOpen {
		t.Fatal("tab should close the browser")
	}
	if got := f.dirInput.Value(); got != "/work/questmaster" {
		t.Fatalf("tab did not accept selection: got %q", got)
	}
	if f.focus == fieldDir {
		t.Fatal("tab should advance focus past the dir field")
	}
}

func TestDirList_NavigationMovesSelection(t *testing.T) {
	f := recentsForm(t, "", []string{"/a/one", "/a/two", "/a/three"})

	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyCtrlR})
	if f.dirIndex != 0 {
		t.Fatalf("initial selection = %d, want 0", f.dirIndex)
	}
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyDown})
	if f.dirIndex != 1 {
		t.Fatalf("after down, selection = %d, want 1", f.dirIndex)
	}
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyUp})
	if f.dirIndex != 0 {
		t.Fatalf("after up, selection = %d, want 0", f.dirIndex)
	}
}

func TestDirList_NoRecentsDoesNotOpen(t *testing.T) {
	f := recentsForm(t, "", nil)
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyCtrlR})
	if f.dirListOpen {
		t.Fatal("ctrl+r should be a no-op with no recents")
	}
}

func TestDirList_TabCompletionStillWorksWhenClosed(t *testing.T) {
	root := makeDirs(t, "packages")
	f := recentsForm(t, root+"/pack", []string{"/some/recent"})
	// List is closed; Tab must still perform path completion, not open recents.
	f, _ = f.handleKey(tea.KeyMsg{Type: tea.KeyTab})
	if f.dirListOpen {
		t.Fatal("tab should not open the recents browser")
	}
	if got := f.dirInput.Value(); got != root+"/packages/" {
		t.Fatalf("tab completion broke: got %q", got)
	}
}

func TestDirSuggestions_ZoxideFragmentUsesRankedCandidates(t *testing.T) {
	t.Parallel()
	var gotFragment string
	f, _ := NewCreateForm(false, "")
	f.dirQuerier = DirQuerierFunc(func(fragment string) ([]string, error) {
		gotFragment = fragment
		return []string{"/work/questmaster", "/work/questmaster-picker-zoxide"}, nil
	})
	f.dirInput.SetValue("quest")

	cmd := f.refreshDirMatches()
	if cmd == nil {
		t.Fatal("expected zoxide query command")
	}
	f, _ = f.Update(cmd())

	if gotFragment != "quest" {
		t.Fatalf("fragment = %q, want quest", gotFragment)
	}
	want := []string{"/work/questmaster", "/work/questmaster-picker-zoxide"}
	if !reflect.DeepEqual(f.dirMatches, want) {
		t.Fatalf("dirMatches = %v, want %v", f.dirMatches, want)
	}
	if !f.dirListOpen {
		t.Fatal("zoxide results should open the dir list")
	}
}

func TestDirSuggestions_ZoxideEmptyFragmentUsesFullRankedList(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, "")
	f.dirQuerier = DirQuerierFunc(func(fragment string) ([]string, error) {
		if fragment != "" {
			t.Fatalf("fragment = %q, want empty", fragment)
		}
		return []string{"/ranked/one", "/ranked/two"}, nil
	})

	cmd := f.refreshDirMatches()
	if cmd == nil {
		t.Fatal("expected zoxide query command")
	}
	f, _ = f.Update(cmd())

	want := []string{"/ranked/one", "/ranked/two"}
	if !reflect.DeepEqual(f.dirMatches, want) {
		t.Fatalf("dirMatches = %v, want %v", f.dirMatches, want)
	}
}

func TestDirSuggestions_ZoxideAbsentFallsBackToRecents(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, "")
	f.recentDirs = []string{"/work/questmaster-picker-zoxide", "/tmp/scratch", "/work/questmaster"}
	f.dirInput.SetValue("qm")

	cmd := f.refreshDirMatches()
	if cmd != nil {
		t.Fatal("recents fallback should not run an async query")
	}
	want := []string{"/work/questmaster-picker-zoxide", "/work/questmaster"}
	if !reflect.DeepEqual(f.dirMatches, want) {
		t.Fatalf("dirMatches = %v, want %v", f.dirMatches, want)
	}
	if !f.dirListOpen {
		t.Fatal("recents fallback should open the dir list")
	}
}

func TestDirSuggestions_ZoxideErrorIsGracefulEmptyList(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, "")
	f.dirQuerier = DirQuerierFunc(func(string) ([]string, error) {
		return nil, errors.New("zoxide failed")
	})
	f.dirInput.SetValue("quest")

	cmd := f.refreshDirMatches()
	if cmd == nil {
		t.Fatal("expected zoxide query command")
	}
	f, _ = f.Update(cmd())

	if len(f.dirMatches) != 0 {
		t.Fatalf("query error should clear matches, got %v", f.dirMatches)
	}
	if !f.dirListOpen {
		t.Fatal("query error should keep the suggestion list open with an empty state")
	}
}

func TestDirSuggestions_ZoxideEmptyResultIsGracefulEmptyList(t *testing.T) {
	t.Parallel()
	f, _ := NewCreateForm(false, "")
	f.dirQuerier = DirQuerierFunc(func(string) ([]string, error) {
		return nil, nil
	})
	f.dirInput.SetValue("missing")

	cmd := f.refreshDirMatches()
	if cmd == nil {
		t.Fatal("expected zoxide query command")
	}
	f, _ = f.Update(cmd())

	if len(f.dirMatches) != 0 {
		t.Fatalf("empty query result should leave no matches, got %v", f.dirMatches)
	}
	if !f.dirListOpen {
		t.Fatal("empty query result should keep the suggestion list open with an empty state")
	}
}

func TestCreateForm_FreeformAbsolutePathSubmitsWithZoxideQuerier(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	f, _ := NewCreateForm(false, "")
	f.dirQuerier = DirQuerierFunc(func(fragment string) ([]string, error) {
		t.Fatalf("absolute path %q should not call zoxide", fragment)
		return nil, nil
	})
	f.dirInput.SetValue(dir)

	f, cmd := f.handleKey(tea.KeyMsg{Type: tea.KeyEnter})
	if cmd == nil {
		t.Fatal("expected free-form absolute path to submit")
	}
	req, ok := cmd().(createRequestMsg)
	if !ok {
		t.Fatalf("expected createRequestMsg, got %T", cmd())
	}
	if req.dir != dir {
		t.Fatalf("dir = %q, want %q", req.dir, dir)
	}
}
