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

// TestPathHelpers asserts each derived path is rooted under Home (the isolation
// invariant: nothing escapes the Quests home).
func TestPathHelpers(t *testing.T) {
	p := ResolveWith("/tmp/qh")

	cases := []struct {
		name string
		got  string
		want string
	}{
		{"QuestsDir", p.QuestsDir(), "/tmp/qh/quests"},
		{"RuntimeDir", p.RuntimeDir(), "/tmp/qh/runtime"},
		{"SocketDir", p.SocketDir(), "/tmp/qh/run"},
		{"StateRoot", p.StateRoot(), "/tmp/qh/state"},
	}
	for _, c := range cases {
		if c.got != c.want {
			t.Errorf("%s = %q, want %q", c.name, c.got, c.want)
		}
		if !strings.HasPrefix(c.got, p.Home) {
			t.Errorf("%s = %q escapes Home %q", c.name, c.got, p.Home)
		}
	}
}

func TestBranchName(t *testing.T) {
	p := ResolveWith("/tmp/qh")
	cases := map[string]string{
		"ENG-142":          "quest/eng-142",
		"eng-142":          "quest/eng-142",
		"Feature/Auth Fix": "quest/feature-auth-fix",
		"  TRIM-1  ":        "quest/trim-1",
	}
	for in, want := range cases {
		if got := p.BranchName(in); got != want {
			t.Errorf("BranchName(%q) = %q, want %q", in, got, want)
		}
	}
}
