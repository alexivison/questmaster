package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/quests/review"
)

// runQuest executes the quests root with the given env under a temp home and
// returns stdout/stderr and any error.
func runQuest(t *testing.T, e *env, args ...string) (string, error) {
	t.Helper()
	root := newRootCmdWithEnv(e)
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&out)
	root.SetArgs(args)
	err := root.Execute()
	return out.String(), err
}

func testHome(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("QUESTS_HOME", home)
	return home
}

func TestQuestNewAndLs(t *testing.T) {
	home := testHome(t)
	e := defaultEnv()

	out, err := runQuest(t, e, "quest", "new", "ENG-1", "--goal", "do the thing", "--worktree", "webapp/.wt/eng-1")
	if err != nil {
		t.Fatalf("quest new: %v (%s)", err, out)
	}

	// File exists under the Quests home and is a valid quest.
	path := filepath.Join(home, "quests", "ENG-1.html")
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("quest file not written under home: %v", err)
	}
	doc, err := quest.Parse(raw)
	if err != nil {
		t.Fatalf("written quest does not parse: %v", err)
	}
	if err := quest.Validate(doc.Head); err != nil {
		t.Fatalf("written quest invalid: %v", err)
	}
	if doc.Head.ID != "ENG-1" || doc.Head.Goal != "do the thing" {
		t.Errorf("written head = %#v", doc.Head)
	}

	lsOut, err := runQuest(t, e, "quest", "ls")
	if err != nil {
		t.Fatalf("quest ls: %v", err)
	}
	if !strings.Contains(lsOut, "ENG-1") {
		t.Errorf("ls output %q does not list ENG-1", lsOut)
	}
}

func TestQuestEditRejectsCorrupt(t *testing.T) {
	testHome(t)
	e := defaultEnv()
	if _, err := runQuest(t, e, "quest", "new", "ENG-2", "--goal", "original goal"); err != nil {
		t.Fatalf("seed quest: %v", err)
	}

	// Editor corrupts the file: not a parseable quest.
	e.editFile = func(path string) error {
		return os.WriteFile(path, []byte("<html>not a quest</html>"), 0o644)
	}
	if _, err := runQuest(t, e, "quest", "edit", "ENG-2"); err == nil {
		t.Fatalf("quest edit accepted a corrupted save, want rejection")
	}

	// Original must be intact.
	store := e.store()
	doc, err := store.Load("ENG-2")
	if err != nil {
		t.Fatalf("original quest lost after rejected edit: %v", err)
	}
	if doc.Head.Goal != "original goal" {
		t.Errorf("rejected edit clobbered the quest: goal = %q", doc.Head.Goal)
	}
}

func TestQuestEditRoundTrips(t *testing.T) {
	testHome(t)
	e := defaultEnv()
	if _, err := runQuest(t, e, "quest", "new", "ENG-3", "--goal", "before"); err != nil {
		t.Fatalf("seed quest: %v", err)
	}

	// Editor writes a valid modified quest (same id, new goal).
	e.editFile = func(path string) error {
		body, rerr := quest.Render(quest.Quest{ID: "ENG-3", Goal: "after"})
		if rerr != nil {
			return rerr
		}
		return os.WriteFile(path, body, 0o644)
	}
	if _, err := runQuest(t, e, "quest", "edit", "ENG-3"); err != nil {
		t.Fatalf("quest edit valid: %v", err)
	}

	doc, err := e.store().Load("ENG-3")
	if err != nil {
		t.Fatalf("load after edit: %v", err)
	}
	if doc.Head.Goal != "after" {
		t.Errorf("edit did not persist: goal = %q, want after", doc.Head.Goal)
	}
}

// fakeViewer records the worktree/base it was opened with.
type fakeViewer struct {
	worktree, base string
	opened         bool
}

func (f *fakeViewer) Open(worktree, baseRef string) error {
	f.opened = true
	f.worktree = worktree
	f.base = baseRef
	return nil
}

func TestQuestDiffInvokesConfiguredViewer(t *testing.T) {
	testHome(t)
	e := defaultEnv()
	if _, err := runQuest(t, e, "quest", "new", "ENG-4", "--goal", "g", "--worktree", "webapp/.wt/eng-4"); err != nil {
		t.Fatalf("seed quest: %v", err)
	}

	var capturedBin string
	fv := &fakeViewer{}
	e.newViewer = func(bin string) review.DiffViewer {
		capturedBin = bin
		return fv
	}

	// Default viewer is scry.
	t.Setenv(review.ViewerEnv, "")
	if _, err := runQuest(t, e, "quest", "diff", "ENG-4"); err != nil {
		t.Fatalf("quest diff: %v", err)
	}
	if capturedBin != review.DefaultViewer {
		t.Errorf("default viewer = %q, want %q", capturedBin, review.DefaultViewer)
	}
	if !fv.opened || fv.worktree != "webapp/.wt/eng-4" || fv.base != "main" {
		t.Errorf("viewer opened with worktree=%q base=%q (opened=%v)", fv.worktree, fv.base, fv.opened)
	}

	// Override honored via flag.
	if _, err := runQuest(t, e, "quest", "diff", "ENG-4", "--viewer", "delta", "--base", "develop"); err != nil {
		t.Fatalf("quest diff --viewer: %v", err)
	}
	if capturedBin != "delta" {
		t.Errorf("flag override viewer = %q, want delta", capturedBin)
	}
	if fv.base != "develop" {
		t.Errorf("base override = %q, want develop", fv.base)
	}
}

func TestQuestOpenInvokesBrowser(t *testing.T) {
	testHome(t)
	e := defaultEnv()
	if _, err := runQuest(t, e, "quest", "new", "ENG-5", "--goal", "g"); err != nil {
		t.Fatalf("seed quest: %v", err)
	}
	var openedPath string
	e.openInBrowser = func(path string) error { openedPath = path; return nil }
	if _, err := runQuest(t, e, "quest", "open", "ENG-5"); err != nil {
		t.Fatalf("quest open: %v", err)
	}
	// open renders a view-time copy with a live status banner (not the stored file).
	if !strings.HasSuffix(openedPath, ".html") || !strings.Contains(openedPath, "ENG-5") {
		t.Errorf("open path = %q, want a view .html for ENG-5", openedPath)
	}
	viewed, err := os.ReadFile(openedPath)
	if err != nil {
		t.Fatalf("read view file: %v", err)
	}
	if !strings.Contains(string(viewed), "live ▾") {
		t.Errorf("view file should carry the injected status banner")
	}
	// The stored quest file must remain banner-free (view-time only).
	stored, _ := os.ReadFile(e.store().Path("ENG-5"))
	if strings.Contains(string(stored), "live ▾") {
		t.Errorf("stored quest file must not be mutated with the banner")
	}
}

func TestQuestViewPrintsHeadAndRuntime(t *testing.T) {
	testHome(t)
	e := defaultEnv()
	if _, err := runQuest(t, e, "quest", "new", "ENG-6", "--goal", "view me", "--next", "first step"); err != nil {
		t.Fatalf("seed quest: %v", err)
	}
	out, err := runQuest(t, e, "quest", "view", "ENG-6")
	if err != nil {
		t.Fatalf("quest view: %v", err)
	}
	for _, want := range []string{"ENG-6", "view me", "draft", "first step"} {
		if !strings.Contains(out, want) {
			t.Errorf("view output missing %q:\n%s", want, out)
		}
	}
}
