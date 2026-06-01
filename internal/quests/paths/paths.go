// Package paths is the isolation layer: it resolves the Quests namespace
// (state root, tmux prefix, branch prefix) that the reused questmaster spine
// is parameterized on, so Quests runs fully alongside questmaster with zero
// shared state. Values come from defaults, the QUESTS_HOME env var, and flags
// — no config file.
package paths

import (
	"os"
	"path/filepath"
	"strings"
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

// QuestsDir is the quest store: authored quest files live at
// <Home>/quests/<id>.html and their runtime records beside them. Quests are
// per-machine metadata about the work and never live in a repo.
func (p Paths) QuestsDir() string {
	return filepath.Join(p.Home, "quests")
}

// RuntimeDir is the harness runtime scratch dir under the Quests home,
// isolated from questmaster. (Per-quest runtime records live beside the quest
// in QuestsDir; this dir is reserved for harness-wide runtime artifacts.)
func (p Paths) RuntimeDir() string {
	return filepath.Join(p.Home, "runtime")
}

// SocketDir is the isolated directory for sockets/FIFOs (build-spec §11:
// "distinct socket/fifo paths"), namespaced under the Quests home so Quests
// IPC never collides with questmaster's.
func (p Paths) SocketDir() string {
	return filepath.Join(p.Home, "run")
}

// BranchName derives a git branch name for a quest id under the Quests branch
// namespace, e.g. BranchName("ENG-142") == "quest/eng-142". The id is
// lowercased and any character outside [a-z0-9._-] is replaced with '-' so the
// result is always a valid ref component.
func (p Paths) BranchName(questID string) string {
	return p.BranchPrefix + sanitizeRefComponent(questID)
}

// sanitizeRefComponent lowercases and replaces git-ref-unsafe characters.
func sanitizeRefComponent(s string) string {
	s = strings.ToLower(strings.TrimSpace(s))
	var b strings.Builder
	b.Grow(len(s))
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= '0' && r <= '9', r == '.', r == '_', r == '-':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}
	return b.String()
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
