//go:build linux || darwin

package cmd

import (
	"context"
	"strings"
	"testing"

	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
)

// seedQuest writes a quest directly to the store at the given status.
func seedQuest(t *testing.T, id string, status quest.Status, summary string) {
	t.Helper()
	q := &quest.Quest{
		ID:      id,
		Title:   id,
		Status:  status,
		Summary: summary,
		Gates: []quest.Gate{
			{Name: "tests", Type: quest.GateAuto, Check: "cmd:make test"},
			{Name: "review", Type: quest.GateToggle, Before: quest.BeforePR},
		},
	}
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("seed quest %s: %v", id, err)
	}
}

// capturingRunner records every tmux invocation while behaving like
// allPassRunner (no live sessions).
func capturingRunner() (*mockRunner, *[]string) {
	base := allPassRunner()
	var calls []string
	r := &mockRunner{fn: func(ctx context.Context, args ...string) (string, error) {
		calls = append(calls, strings.Join(args, " "))
		return base.fn(ctx, args...)
	}}
	return r, &calls
}

func TestSessionNewOnActiveQuestStampsAndSeedsPrompt(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv("QUESTMASTER_STATE_ROOT", store.Root())
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	prependStubQuestmasterToPath(t)

	seedQuest(t, "DEMO-1", quest.StatusActive, "Bring the shared layout to the web app")

	runner, calls := capturingRunner()
	out := runCmd(t, store, runner, "session", "new", "--quest", "DEMO-1", "--cwd", cwd)
	if !strings.Contains(out, "On quest DEMO-1") {
		t.Fatalf("expected quest note in output, got: %s", out)
	}

	// The new session carries the quest_id.
	m := readOnlyNewManifest(t, store)
	got, err := state.QuestIDForSession(m.SessionID)
	if err != nil {
		t.Fatalf("QuestIDForSession: %v", err)
	}
	if got != "DEMO-1" {
		t.Errorf("session %s quest_id = %q, want DEMO-1", m.SessionID, got)
	}

	// The opening prompt (delivered into the primary pane) carries goal + gates.
	joined := strings.Join(*calls, "\n")
	for _, want := range []string{"Bring the shared layout", "Definition of done", "tests"} {
		if !strings.Contains(joined, want) {
			t.Errorf("seeded prompt missing %q", want)
		}
	}
}

func TestSessionNewRefusesNonActiveQuest(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv("QUESTMASTER_STATE_ROOT", store.Root())
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)

	seedQuest(t, "WIP-1", quest.StatusWIP, "draft")
	seedQuest(t, "DONE-1", quest.StatusDone, "turned in")

	for _, id := range []string{"WIP-1", "DONE-1"} {
		_, err := runCmdErr(t, store, allPassRunner(), "session", "new", "--quest", id, "--cwd", cwd)
		if err == nil {
			t.Errorf("session new on %s should be refused (only active is attachable)", id)
		} else if !strings.Contains(err.Error(), "only active quests are attachable") {
			t.Errorf("unexpected refusal error for %s: %v", id, err)
		}
	}
}

func TestSessionNewRefusesQuestOnWorker(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv("QUESTMASTER_STATE_ROOT", store.Root())
	seedQuest(t, "DEMO-1", quest.StatusActive, "goal")

	_, err := runCmdErr(t, store, allPassRunner(), "session", "new", "--quest", "DEMO-1", "--master-id", "qm-999")
	if err == nil || !strings.Contains(err.Error(), "workers inherit") {
		t.Fatalf("expected refusal for --quest with --master-id, got: %v", err)
	}
}

func TestSessionAttachRefusesNonActiveQuest(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv("QUESTMASTER_STATE_ROOT", store.Root())
	seedQuest(t, "WIP-1", quest.StatusWIP, "draft")

	_, err := runCmdErr(t, store, allPassRunner(), "session", "attach", "qm-123", "--quest", "WIP-1")
	if err == nil || !strings.Contains(err.Error(), "only active quests are attachable") {
		t.Fatalf("attach on a wip quest should be refused, got: %v", err)
	}
}

func TestSessionDetachClears(t *testing.T) {
	store := setupStore(t)
	t.Setenv("QUESTMASTER_STATE_ROOT", store.Root())

	if err := state.StampQuest("qm-555", "DEMO-1"); err != nil {
		t.Fatalf("stamp: %v", err)
	}
	out := runCmd(t, store, allPassRunner(), "session", "detach", "qm-555")
	if !strings.Contains(out, "Detached qm-555") {
		t.Errorf("unexpected detach output: %s", out)
	}
	got, _ := state.QuestIDForSession("qm-555")
	if got != "" {
		t.Errorf("after detach, quest_id = %q, want empty", got)
	}
}
