package gate

import (
	"path/filepath"
	"strings"
	"testing"
)

func TestSidecarRoundTrip(t *testing.T) {
	s := NewSidecar(filepath.Join(t.TempDir(), "runtime"))
	results := []Result{
		{Gate: "tests", Status: StatusPass, Output: "ok"},
		{Gate: "ci", Status: StatusFail, Output: "boom"},
		{Gate: "build", Status: StatusError, Output: "command not found"},
	}
	if err := s.Save("AEGIS-3", results); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := s.Load("AEGIS-3")
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.QuestID != "AEGIS-3" || len(got.Gates) != 3 {
		t.Fatalf("round-trip mismatch: %+v", got)
	}
	if got.Gates["ci"].Status != StatusFail || got.Gates["ci"].Output != "boom" {
		t.Errorf("ci result not preserved: %+v", got.Gates["ci"])
	}
	sm := got.StatusMap()
	if sm["tests"] != "pass" || sm["ci"] != "fail" || sm["build"] != "error" {
		t.Errorf("StatusMap = %v", sm)
	}
}

func TestSidecarLoadMissingIsEmpty(t *testing.T) {
	s := NewSidecar(filepath.Join(t.TempDir(), "runtime"))
	got, err := s.Load("UNSEEN-1")
	if err != nil {
		t.Fatalf("Load on missing: %v", err)
	}
	if len(got.Gates) != 0 {
		t.Errorf("missing quest should have no results, got %+v", got)
	}
}

// TestSidecarPathUnderHomeNotRepo mirrors the quest store guard: the sidecar
// lives under qm's dotfiles, never a repo/worktree path.
func TestSidecarPathUnderHomeNotRepo(t *testing.T) {
	home := t.TempDir()
	dir := filepath.Join(home, "runtime")
	s := NewSidecar(dir)
	if err := s.Save("ENG-1", []Result{{Gate: "t", Status: StatusPass}}); err != nil {
		t.Fatalf("Save: %v", err)
	}
	p := s.path("ENG-1")
	if !strings.HasPrefix(p, dir) || !strings.HasPrefix(p, home) {
		t.Errorf("sidecar path %q not under home %q", p, home)
	}
	for _, repoish := range []string{"/.wt/", "/worktree", "questmaster/internal", "/.git/"} {
		if strings.Contains(p, repoish) {
			t.Errorf("sidecar path %q looks like it points into a repo (%q)", p, repoish)
		}
	}
}

func TestSidecarRejectsUnsafeID(t *testing.T) {
	s := NewSidecar(t.TempDir())
	if err := s.Save("../escape", []Result{{Gate: "t", Status: StatusPass}}); err == nil {
		t.Fatalf("Save accepted an unsafe id")
	}
}
