package paths

import (
	"path/filepath"
	"strings"
	"testing"
)

// TestResolveDefaultUnderHome asserts the default Quests home is ~/.quests and
// its state root is distinct from questmaster's ~/.questmaster-state. This is
// the Stage-1 isolation gate (T0): Quests must not share questmaster's state.
func TestResolveDefaultUnderHome(t *testing.T) {
	t.Setenv(HomeEnv, "")
	t.Setenv("HOME", "/home/tester")

	p := Resolve()

	wantHome := "/home/tester/.quests"
	if p.Home != wantHome {
		t.Errorf("Home = %q, want %q", p.Home, wantHome)
	}
	if got, want := p.StateRoot(), "/home/tester/.quests/state"; got != want {
		t.Errorf("StateRoot() = %q, want %q", got, want)
	}

	// Must be rooted under ~/.quests and never under questmaster's root.
	if !strings.HasPrefix(p.StateRoot(), wantHome) {
		t.Errorf("StateRoot() %q not under Quests home %q", p.StateRoot(), wantHome)
	}
	questmasterRoot := filepath.Join("/home/tester", ".questmaster-state")
	if strings.HasPrefix(p.StateRoot(), questmasterRoot) {
		t.Errorf("StateRoot() %q must not be under questmaster root %q", p.StateRoot(), questmasterRoot)
	}
}

// TestResolveEnvOverride asserts QUESTS_HOME wins over the default.
func TestResolveEnvOverride(t *testing.T) {
	t.Setenv("HOME", "/home/tester")
	t.Setenv(HomeEnv, "/tmp/quests-dev")

	p := Resolve()

	if p.Home != "/tmp/quests-dev" {
		t.Errorf("Home = %q, want /tmp/quests-dev", p.Home)
	}
	if got, want := p.StateRoot(), "/tmp/quests-dev/state"; got != want {
		t.Errorf("StateRoot() = %q, want %q", got, want)
	}
}

// TestResolveWithFlagPrecedence asserts an explicit flag wins over env and default.
func TestResolveWithFlagPrecedence(t *testing.T) {
	t.Setenv("HOME", "/home/tester")
	t.Setenv(HomeEnv, "/tmp/quests-env")

	p := ResolveWith("/tmp/quests-flag")

	if p.Home != "/tmp/quests-flag" {
		t.Errorf("Home = %q, want /tmp/quests-flag (flag should win)", p.Home)
	}
}

// TestNamespaceConstants pins the Quests namespace labels carried for
// Quests-owned naming (cockpit, Stage 2+ worktrees) and the eventual cutover.
func TestNamespaceConstants(t *testing.T) {
	p := Resolve()
	if p.TmuxPrefix != "quests" {
		t.Errorf("TmuxPrefix = %q, want quests", p.TmuxPrefix)
	}
	if p.BranchPrefix != "quest/" {
		t.Errorf("BranchPrefix = %q, want quest/", p.BranchPrefix)
	}
}
