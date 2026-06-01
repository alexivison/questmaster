// Package paths is the isolation layer: it resolves the Quests namespace
// (state root, tmux prefix, branch prefix) that the reused questmaster spine
// is parameterized on, so Quests runs fully alongside questmaster with zero
// shared state. Values come from defaults, the QUESTS_HOME env var, and flags
// — no config file.
package paths

import (
	"os"
	"path/filepath"
)

const (
	// HomeEnv overrides the Quests home directory.
	HomeEnv = "QUESTS_HOME"

	// DefaultHomeDir is the home directory name under $HOME used when
	// QUESTS_HOME is unset.
	DefaultHomeDir = ".quests"

	// DefaultTmuxPrefix is the tmux/session namespace label for Quests.
	DefaultTmuxPrefix = "quests"

	// DefaultBranchPrefix is the git branch namespace for Quests worktrees.
	DefaultBranchPrefix = "quest/"
)

// Paths is the resolved Quests namespace. It is the single value the shared
// spine (state, tmux, session/branch naming) is parameterized on.
type Paths struct {
	Home         string // QUESTS_HOME; default ~/.quests
	TmuxPrefix   string // "quests"
	BranchPrefix string // "quest/"
}

// Resolve returns the Quests paths from defaults overlaid by the environment
// (QUESTS_HOME). Flag overrides are applied by the CLI via ResolveWith.
func Resolve() Paths {
	return ResolveWith("")
}

// ResolveWith resolves the Quests paths with an optional explicit home that
// takes precedence over the environment and default. An empty homeFlag falls
// back to QUESTS_HOME, then to ~/.quests. Precedence: flag <- env <- default.
func ResolveWith(homeFlag string) Paths {
	home := homeFlag
	if home == "" {
		home = os.Getenv(HomeEnv)
	}
	if home == "" {
		home = filepath.Join(homeDir(), DefaultHomeDir)
	}
	return Paths{
		Home:         home,
		TmuxPrefix:   DefaultTmuxPrefix,
		BranchPrefix: DefaultBranchPrefix,
	}
}

// StateRoot is where per-session state lives, isolated under the Quests home.
// This is the value injected into the reused state spine (it intentionally
// does not share questmaster's ~/.questmaster-state root).
func (p Paths) StateRoot() string {
	return filepath.Join(p.Home, "state")
}

// homeDir returns the user's home directory, preferring $HOME (matching the
// questmaster spine's resolution) and falling back to os.UserHomeDir.
func homeDir() string {
	if h := os.Getenv("HOME"); h != "" {
		return h
	}
	h, _ := os.UserHomeDir()
	return h
}
