package main

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
)

// fakeSpawn returns a spawnSession stub that records the last opts/agent and
// creates a manifest in the Quests state store (so the session shows up in the
// roster / session ls), without touching tmux.
func fakeSpawn(e *env, lastOpts *session.StartOpts, lastAgent *string) func(context.Context, session.StartOpts, string) (session.StartResult, error) {
	n := 0
	return func(_ context.Context, opts session.StartOpts, agentName string) (session.StartResult, error) {
		if lastOpts != nil {
			*lastOpts = opts
		}
		if lastAgent != nil {
			*lastAgent = agentName
		}
		n++
		id := fmt.Sprintf("qm-%d", 1000+n)
		store, err := state.NewStore(e.paths.StateRoot())
		if err != nil {
			return session.StartResult{}, err
		}
		st := ""
		if opts.Master {
			st = "master"
		}
		if err := store.Create(state.Manifest{SessionID: id, Title: opts.Title, Cwd: opts.Cwd, SessionType: st}); err != nil {
			return session.StartResult{}, err
		}
		return session.StartResult{SessionID: id, RuntimeDir: "/tmp/" + id}, nil
	}
}

func TestSessionNewFreeAppearsInRoster(t *testing.T) {
	testHome(t)
	e := defaultEnv()
	var opts session.StartOpts
	e.spawnSession = fakeSpawn(e, &opts, nil)

	out, err := runQuest(t, e, "session", "new", "myproj")
	if err != nil {
		t.Fatalf("session new: %v (%s)", err, out)
	}
	if !opts.Detached {
		t.Error("free session must spawn detached (parity with questmaster)")
	}
	if opts.Master {
		t.Error("a solo session must not be a master")
	}
	if opts.Title != "myproj" {
		t.Errorf("title = %q, want myproj", opts.Title)
	}

	// Appears in the state store the agents tracker reads (DiscoverSessions).
	manifests, err := state.OpenStore(e.paths.StateRoot()).DiscoverSessions()
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	if len(manifests) != 1 {
		t.Fatalf("state store has %d sessions, want 1", len(manifests))
	}
	if manifests[0].Title != "myproj" {
		t.Errorf("session title = %q, want myproj", manifests[0].Title)
	}
}

func TestSessionNewMasterRole(t *testing.T) {
	testHome(t)
	e := defaultEnv()
	var opts session.StartOpts
	e.spawnSession = fakeSpawn(e, &opts, nil)
	if _, err := runQuest(t, e, "session", "new", "lead", "--role", "master"); err != nil {
		t.Fatalf("session new --role master: %v", err)
	}
	if !opts.Master {
		t.Error("--role master should spawn a master session")
	}
}

func TestSessionNewAgentOverride(t *testing.T) {
	testHome(t)
	e := defaultEnv()
	var agentName string
	e.spawnSession = fakeSpawn(e, nil, &agentName)
	if _, err := runQuest(t, e, "session", "new", "x", "--agent", "codex"); err != nil {
		t.Fatalf("session new --agent: %v", err)
	}
	if agentName != "codex" {
		t.Errorf("agent override = %q, want codex", agentName)
	}
}

func TestSessionNewAttachesQuestHat(t *testing.T) {
	testHome(t)
	e := defaultEnv()
	e.spawnSession = fakeSpawn(e, nil, nil)
	if _, err := runQuest(t, e, "session", "new", "work", "--quest", "ENG-7"); err != nil {
		t.Fatalf("session new --quest: %v", err)
	}

	store := state.OpenStore(e.paths.StateRoot())
	manifests, err := store.DiscoverSessions()
	if err != nil || len(manifests) != 1 {
		t.Fatalf("discover: %v (%d)", err, len(manifests))
	}
	m := manifests[0]
	if m.QuestID != "ENG-7" {
		t.Errorf("QuestID = %q, want ENG-7", m.QuestID)
	}
	if m.Mode != state.ModeInteractive {
		t.Errorf("Mode = %q, want %q", m.Mode, state.ModeInteractive)
	}
}

func TestSessionNewRejectsUnknownRole(t *testing.T) {
	testHome(t)
	e := defaultEnv()
	e.spawnSession = fakeSpawn(e, nil, nil)
	if _, err := runQuest(t, e, "session", "new", "x", "--role", "bogus"); err == nil {
		t.Error("unknown role should error")
	}
}

func TestSessionLs(t *testing.T) {
	testHome(t)
	e := defaultEnv()
	e.spawnSession = fakeSpawn(e, nil, nil)
	if _, err := runQuest(t, e, "session", "new", "alpha"); err != nil {
		t.Fatalf("seed session: %v", err)
	}
	out, err := runQuest(t, e, "session", "ls")
	if err != nil {
		t.Fatalf("session ls: %v", err)
	}
	if !strings.Contains(out, "alpha") {
		t.Errorf("session ls output %q missing the session", out)
	}
}

// TestQuestNewPlanProducesValidFileAndPlanningSession covers the planning-flow
// acceptance: a planning session authors a quest -> a valid file under Home.
func TestQuestNewPlanProducesValidFileAndPlanningSession(t *testing.T) {
	home := testHome(t)
	e := defaultEnv()
	var opts session.StartOpts
	e.spawnSession = fakeSpawn(e, &opts, nil)

	out, err := runQuest(t, e, "quest", "new", "ENG-9", "--goal", "plan me", "--plan")
	if err != nil {
		t.Fatalf("quest new --plan: %v (%s)", err, out)
	}

	// Valid quest file under Home.
	doc, err := e.store().Load("ENG-9")
	if err != nil {
		t.Fatalf("planning flow did not produce a quest file: %v", err)
	}
	if !strings.HasPrefix(e.store().Path("ENG-9"), home) {
		t.Errorf("quest file %q not under Home %q", e.store().Path("ENG-9"), home)
	}
	if doc.Head.Goal != "plan me" {
		t.Errorf("quest goal = %q, want plan me", doc.Head.Goal)
	}

	// A planning session was spawned for it.
	if !opts.Master {
		t.Error("planning session should be a master")
	}
	if !strings.Contains(opts.Prompt, "ENG-9") {
		t.Errorf("planning prompt should reference the quest, got %q", opts.Prompt)
	}

	// The planning session wears the quest hat.
	manifests, _ := state.OpenStore(e.paths.StateRoot()).DiscoverSessions()
	if len(manifests) != 1 || manifests[0].QuestID != "ENG-9" {
		t.Errorf("planning session should be attached to ENG-9, got %+v", manifests)
	}
}
