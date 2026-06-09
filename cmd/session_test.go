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
	seedQuestProject(t, id, status, summary, "")
}

// seedQuestProject writes a quest with a project stamp, for project-grouping tests.
func seedQuestProject(t *testing.T, id string, status quest.Status, summary, project string) {
	t.Helper()
	q := &quest.Quest{
		ID:      id,
		Title:   id,
		Status:  status,
		Summary: summary,
		Project: project,
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

func TestSessionNewWorkerOnActiveQuestStampsAndSeedsPrompt(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv("QUESTMASTER_STATE_ROOT", store.Root())
	masterCwd := t.TempDir()
	workerCwd := t.TempDir()
	writeAgentConfig(t, workerCwd)
	prependStubQuestmasterToPath(t)
	createManifest(t, store, "qm-master", "orch", masterCwd, "master")
	seedQuest(t, "DEMO-1", quest.StatusActive, "goal")

	userPrompt := "check the failing worker test"
	runner, calls := capturingRunner()
	out := runCmd(t, store, runner,
		"session", "new",
		"--master-id", "qm-master",
		"--quest", "DEMO-1",
		"--cwd", workerCwd,
		"--prompt", userPrompt,
		"worker-title",
	)
	if !strings.Contains(out, "On quest DEMO-1") {
		t.Fatalf("expected quest note in output, got: %s", out)
	}

	m := readOnlyNewManifest(t, store, "qm-master")
	if got := m.ExtraString("parent_session"); got != "qm-master" {
		t.Fatalf("worker parent_session = %q, want qm-master", got)
	}
	if got := m.Cwd; got != workerCwd {
		t.Fatalf("worker cwd = %q, want %q", got, workerCwd)
	}
	got, err := state.QuestIDForSession(m.SessionID)
	if err != nil {
		t.Fatalf("QuestIDForSession: %v", err)
	}
	if got != "DEMO-1" {
		t.Errorf("worker %s quest_id = %q, want DEMO-1", m.SessionID, got)
	}

	joined := strings.Join(*calls, "\n")
	for _, want := range []string{"goal", "Definition of done", "tests", userPrompt} {
		if !strings.Contains(joined, want) {
			t.Errorf("worker seeded prompt missing %q", want)
		}
	}
}

func TestSessionNewWorkerRefusesNonActiveQuest(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv("QUESTMASTER_STATE_ROOT", store.Root())
	cwd := t.TempDir()
	writeAgentConfig(t, cwd)
	createManifest(t, store, "qm-master", "orch", cwd, "master")

	seedQuest(t, "WIP-1", quest.StatusWIP, "draft")
	seedQuest(t, "DONE-1", quest.StatusDone, "turned in")

	for _, id := range []string{"WIP-1", "DONE-1"} {
		_, err := runCmdErr(t, store, allPassRunner(),
			"session", "new", "--master-id", "qm-master", "--quest", id, "--cwd", cwd,
		)
		if err == nil {
			t.Errorf("worker session new on %s should be refused", id)
		} else if !strings.Contains(err.Error(), "only active quests are attachable") {
			t.Errorf("unexpected refusal error for %s: %v", id, err)
		}
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

// TestSessionAttachRollsBackStampOnInjectFailure asserts a failed brief
// delivery does not leave quest_id behind: the relay fails (the session is not
// running), so the stamp written just before it must be rolled back.
func TestSessionAttachRollsBackStampOnInjectFailure(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv("QUESTMASTER_STATE_ROOT", store.Root())
	seedQuest(t, "DEMO-1", quest.StatusActive, "goal")

	// allPassRunner reports has-session as not running, so injectWorkingBrief
	// (a relay) fails after StampQuest.
	_, err := runCmdErr(t, store, allPassRunner(), "session", "attach", "qm-777", "--quest", "DEMO-1")
	if err == nil {
		t.Fatal("attach should fail when the brief cannot be delivered")
	}
	if !strings.Contains(err.Error(), "inject quest brief") {
		t.Errorf("unexpected error: %v", err)
	}
	if got, _ := state.QuestIDForSession("qm-777"); got != "" {
		t.Errorf("attach left a stale quest_id %q after a failed inject; want it rolled back", got)
	}
}

func TestSessionAttachWorkerStampsAndInjects(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv("QUESTMASTER_STATE_ROOT", store.Root())
	seedQuest(t, "DEMO-1", quest.StatusActive, "worker goal")
	createManifest(t, store, "qm-master", "orch", t.TempDir(), "master")
	createWorkerManifest(t, store, "qm-worker", "qm-master")

	out := runCmd(t, store, messagingRunner("qm-worker"), "session", "attach", "qm-worker", "--quest", "DEMO-1")
	if !strings.Contains(out, "Attached qm-worker to quest DEMO-1") {
		t.Fatalf("unexpected attach output: %s", out)
	}
	got, err := state.QuestIDForSession("qm-worker")
	if err != nil {
		t.Fatalf("QuestIDForSession: %v", err)
	}
	if got != "DEMO-1" {
		t.Fatalf("worker quest_id = %q, want DEMO-1", got)
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
