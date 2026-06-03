package gate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunCheckPass(t *testing.T) {
	r := RunCheck("tests", "cmd:true", t.TempDir())
	if r.Status != StatusPass {
		t.Errorf("exit 0 → %q, want pass", r.Status)
	}
}

func TestRunCheckFailWithOutput(t *testing.T) {
	r := RunCheck("tests", "cmd:echo boom; exit 1", t.TempDir())
	if r.Status != StatusFail {
		t.Errorf("nonzero with output → %q, want fail", r.Status)
	}
	if !strings.Contains(r.Output, "boom") {
		t.Errorf("output not captured: %q", r.Output)
	}
	if r.Misconfigured() {
		t.Errorf("a real failure must not read as misconfigured")
	}
}

func TestRunCheckMissingCommandIsError(t *testing.T) {
	r := RunCheck("tests", "cmd:definitely-not-a-real-command-xyz", t.TempDir())
	if r.Status != StatusError {
		t.Errorf("missing command → %q, want error (misconfigured)", r.Status)
	}
	if !r.Misconfigured() {
		t.Errorf("a command-not-found must read as misconfigured, not fail")
	}
}

func TestRunCheckUnsupportedTypeIsError(t *testing.T) {
	for _, check := range []string{"github:checks", "typecheck", "lint", "coverage:80"} {
		r := RunCheck("g", check, t.TempDir())
		if r.Status != StatusError {
			t.Errorf("check %q → %q, want error (cmd: only)", check, r.Status)
		}
	}
}

func TestRunCheckRunsInWorktree(t *testing.T) {
	dir := t.TempDir()
	r := RunCheck("pwd", "cmd:pwd", dir)
	if r.Status != StatusPass {
		t.Fatalf("pwd → %q, want pass", r.Status)
	}
	// macOS /tmp is a symlink to /private/tmp; compare resolved paths.
	wantResolved, _ := filepath.EvalSymlinks(dir)
	gotResolved, _ := filepath.EvalSymlinks(strings.TrimSpace(r.Output))
	if gotResolved != wantResolved {
		t.Errorf("ran in %q, want worktree %q", strings.TrimSpace(r.Output), dir)
	}
}

func TestRunCheckCreatesNoFiles(t *testing.T) {
	dir := t.TempDir()
	_ = RunCheck("noop", "cmd:true", dir)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("readdir: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("runner created files in the worktree: %v", entries)
	}
}
