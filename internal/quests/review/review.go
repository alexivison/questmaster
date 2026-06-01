// Package review is the swappable diff-viewer slot. `quest diff` resolves a
// quest's worktree + base and shells out to an external viewer (default scry,
// since it's the one we own and can later teach to talk to the loop;
// overridable via flag or env). Nothing is embedded in the cockpit — review is
// a launched viewer, not an inline render.
package review

import (
	"os"
	"os/exec"
)

const (
	// DefaultViewer is the diff viewer used when none is configured.
	DefaultViewer = "scry"
	// ViewerEnv overrides the default viewer (e.g. delta, difftastic).
	ViewerEnv = "QUESTS_DIFF_VIEWER"
)

// DiffViewer launches a review of a quest's worktree against a base ref.
type DiffViewer interface {
	Open(worktree, baseRef string) error
}

// CommandViewer shells out to an external diff viewer binary. Run is
// injectable so the assembled command can be asserted in tests.
type CommandViewer struct {
	Bin string
	Run func(bin string, args ...string) error
}

var _ DiffViewer = (*CommandViewer)(nil)

// ResolveViewer applies precedence: explicit flag <- QUESTS_DIFF_VIEWER <-
// scry.
func ResolveViewer(flag string) string {
	if flag != "" {
		return flag
	}
	if env := os.Getenv(ViewerEnv); env != "" {
		return env
	}
	return DefaultViewer
}

// NewViewer returns a CommandViewer for bin (resolved via ResolveViewer if
// empty), executing real commands with inherited stdio.
func NewViewer(bin string) *CommandViewer {
	return &CommandViewer{Bin: ResolveViewer(bin), Run: execRun}
}

// Open invokes the viewer against the worktree and base ref. Arguments are
// passed as `<bin> --base <baseRef> <worktree>`; viewers that need a different
// shape are configured by swapping the binary.
func (v *CommandViewer) Open(worktree, baseRef string) error {
	return v.Run(v.Bin, "--base", baseRef, worktree)
}

func execRun(bin string, args ...string) error {
	cmd := exec.Command(bin, args...)
	cmd.Stdin = os.Stdin
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}
