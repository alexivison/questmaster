//go:build linux || darwin

package cmd

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/quests/gate"
	"github.com/alexivison/questmaster/internal/quests/quest"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

func TestQuestLoopFailsInjectsThenStopsGreen(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	worktree := t.TempDir()
	sessionID := "qm-loop"
	questID := "LOOP-1"

	saveQuest(t, questID, quest.StatusActive, []quest.Gate{
		{Name: "tests", Type: quest.GateAuto, Check: "cmd:test -f fixed"},
	})
	createManifest(t, store, sessionID, "loop", worktree, "standalone")
	if err := state.StampQuest(sessionID, questID); err != nil {
		t.Fatalf("stamp quest: %v", err)
	}

	runner := newLoopCommandRunner(sessionID)
	out, done := startQuestLoopCommand(t, store, runner, "quest", "loop", sessionID, "--max-time", "5s", "--max-iters", "5")
	waitForQuestLoopMarker(t, sessionID)

	writeLoopPaneState(t, sessionID, "done", 1)
	msg := readRelayInstruction(t, runner.waitForSend(t))
	if !strings.Contains(msg, "Failing gates: tests") {
		t.Fatalf("injected message missing gate name:\n%s", msg)
	}
	if !strings.Contains(strings.ToLower(msg), "fix the work so the check passes") {
		t.Fatalf("injected message missing fix-work directive:\n%s", msg)
	}
	for _, forbidden := range []string{"pass the gate", "approve", "mark done", "set status"} {
		if strings.Contains(strings.ToLower(msg), forbidden) {
			t.Fatalf("injected message contains forbidden phrase %q:\n%s", forbidden, msg)
		}
	}

	if err := os.WriteFile(filepath.Join(worktree, "fixed"), []byte("ok\n"), 0o644); err != nil {
		t.Fatalf("write fixed marker: %v", err)
	}
	writeLoopPaneState(t, sessionID, "working", 2)
	writeLoopPaneState(t, sessionID, "done", 3)

	if err := waitLoopDone(t, done); err != nil {
		t.Fatalf("quest loop command: %v\noutput:\n%s", err, out.String())
	}
	gotOut := out.String()
	for _, want := range []string{
		"qm quest loop armed",
		"iteration 1: fail",
		"iteration 2: green",
		"terminal: all autos green",
	} {
		if !strings.Contains(gotOut, want) {
			t.Fatalf("output missing %q:\n%s", want, gotOut)
		}
	}
	if got := runner.sentCount(); got != 1 {
		t.Fatalf("send count = %d, want 1", got)
	}
	if marker := loadQuestLoopMarker(t, sessionID); marker != nil {
		t.Fatalf("quest loop marker was not cleared: %+v", marker)
	}
	loaded, err := gate.NewSidecar(questRuntimeDir()).Load(questID)
	if err != nil {
		t.Fatalf("load sidecar: %v", err)
	}
	if loaded.Gates["tests"].Status != gate.StatusPass {
		t.Fatalf("sidecar tests status = %q, want pass", loaded.Gates["tests"].Status)
	}
}

func TestQuestLoopContinuesWhenSidecarPersistFails(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	sessionID := "qm-sidecar-fail"
	questID := "SIDECAR-1"

	saveQuest(t, questID, quest.StatusActive, []quest.Gate{
		{Name: "tests", Type: quest.GateAuto, Check: "cmd:true"},
	})
	createManifest(t, store, sessionID, "sidecar", t.TempDir(), "standalone")
	if err := state.StampQuest(sessionID, questID); err != nil {
		t.Fatalf("stamp quest: %v", err)
	}

	// Force the sidecar write to fail by occupying the runtime dir path with a
	// regular file, so Save's MkdirAll errors. A render-only persistence failure
	// must not abort the loop or discard the computed (green) verdict.
	if err := os.WriteFile(questRuntimeDir(), []byte("not a dir\n"), 0o644); err != nil {
		t.Fatalf("seed broken runtime path: %v", err)
	}

	runner := newLoopCommandRunner(sessionID)
	out, done := startQuestLoopCommand(t, store, runner, "quest", "loop", sessionID, "--max-iters", "1", "--max-time", "5s")
	waitForQuestLoopMarker(t, sessionID)
	writeLoopPaneState(t, sessionID, "done", 1)

	if err := waitLoopDone(t, done); err != nil {
		t.Fatalf("loop aborted on render-only sidecar persist failure: %v\noutput:\n%s", err, out.String())
	}
	got := out.String()
	for _, want := range []string{"warning: persisting auto-gate results failed", "iteration 1: green", "terminal: all autos green"} {
		if !strings.Contains(got, want) {
			t.Fatalf("output missing %q:\n%s", want, got)
		}
	}
	if got := runner.sentCount(); got != 0 {
		t.Fatalf("green-on-first-iteration injected %d message(s), want 0", got)
	}
}

func TestQuestLoopMisconfiguredSurfacesWithoutInjection(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	sessionID := "qm-misconfig"
	questID := "BAD-1"

	saveQuest(t, questID, quest.StatusActive, []quest.Gate{
		{Name: "build", Type: quest.GateAuto, Check: "badprefix:thing"},
	})
	createManifest(t, store, sessionID, "loop", t.TempDir(), "standalone")
	if err := state.StampQuest(sessionID, questID); err != nil {
		t.Fatalf("stamp quest: %v", err)
	}

	runner := newLoopCommandRunner(sessionID)
	out, done := startQuestLoopCommand(t, store, runner, "quest", "loop", sessionID, "--max-time", "5s")
	waitForQuestLoopMarker(t, sessionID)
	writeLoopPaneState(t, sessionID, "done", 1)

	if err := waitLoopDone(t, done); err != nil {
		t.Fatalf("quest loop command: %v\noutput:\n%s", err, out.String())
	}
	wantLine := "gate build misconfigured (unsupported check badprefix:thing (supported: cmd:<shell> or github:{checks|checks-green|review-approved|pr-approved|pr-merged|merged}[:<pr-number-or-url>])) — fix the quest's check; not injected"
	if !strings.Contains(out.String(), wantLine) {
		t.Fatalf("missing misconfigured line:\nwant: %s\nout:\n%s", wantLine, out.String())
	}
	if got := runner.sentCount(); got != 0 {
		t.Fatalf("misconfigured check injected %d message(s), want 0", got)
	}
}

func TestQuestLoopBudgetStopsWithLastVerdict(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	sessionID := "qm-budget"
	questID := "BUDGET-1"

	saveQuest(t, questID, quest.StatusActive, []quest.Gate{
		{Name: "tests", Type: quest.GateAuto, Check: "cmd:false"},
	})
	createManifest(t, store, sessionID, "budget", t.TempDir(), "standalone")
	if err := state.StampQuest(sessionID, questID); err != nil {
		t.Fatalf("stamp quest: %v", err)
	}

	runner := newLoopCommandRunner(sessionID)
	out, done := startQuestLoopCommand(t, store, runner, "quest", "loop", sessionID, "--max-iters", "1", "--max-time", "5s")
	waitForQuestLoopMarker(t, sessionID)
	writeLoopPaneState(t, sessionID, "done", 1)

	if err := waitLoopDone(t, done); err != nil {
		t.Fatalf("quest loop command: %v\noutput:\n%s", err, out.String())
	}
	got := out.String()
	for _, want := range []string{"terminal: stopped (budget)", "last verdict:", "fail          tests"} {
		if !strings.Contains(got, want) {
			t.Fatalf("output missing %q:\n%s", want, got)
		}
	}
	if got := runner.sentCount(); got != 0 {
		t.Fatalf("budget stop injected %d message(s), want 0", got)
	}
}

func TestQuestLoopStuckStopsWithLastVerdict(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	sessionID := "qm-stuck"
	questID := "STUCK-1"

	saveQuest(t, questID, quest.StatusActive, []quest.Gate{
		{Name: "tests", Type: quest.GateAuto, Check: "cmd:echo same failure; exit 1"},
	})
	createManifest(t, store, sessionID, "stuck", t.TempDir(), "standalone")
	if err := state.StampQuest(sessionID, questID); err != nil {
		t.Fatalf("stamp quest: %v", err)
	}

	runner := newLoopCommandRunner(sessionID)
	out, done := startQuestLoopCommand(t, store, runner, "quest", "loop", sessionID, "--stuck-after", "2", "--max-time", "5s")
	waitForQuestLoopMarker(t, sessionID)
	writeLoopPaneState(t, sessionID, "done", 1)
	_ = runner.waitForSend(t)
	writeLoopPaneState(t, sessionID, "working", 2)
	writeLoopPaneState(t, sessionID, "done", 3)

	if err := waitLoopDone(t, done); err != nil {
		t.Fatalf("quest loop command: %v\noutput:\n%s", err, out.String())
	}
	got := out.String()
	for _, want := range []string{"terminal: stopped (stuck)", "last verdict:", "fail          tests"} {
		if !strings.Contains(got, want) {
			t.Fatalf("output missing %q:\n%s", want, got)
		}
	}
	if got := runner.sentCount(); got != 1 {
		t.Fatalf("stuck run injected %d message(s), want 1", got)
	}
}

func TestQuestLoopBlockedTimeoutStopsWithoutInjection(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	sessionID := "qm-blocked-loop"
	questID := "BLOCKED-1"

	saveQuest(t, questID, quest.StatusActive, []quest.Gate{
		{Name: "tests", Type: quest.GateAuto, Check: "cmd:true"},
	})
	createManifest(t, store, sessionID, "blocked", t.TempDir(), "standalone")
	if err := state.StampQuest(sessionID, questID); err != nil {
		t.Fatalf("stamp quest: %v", err)
	}

	runner := newLoopCommandRunner(sessionID)
	var out bytes.Buffer
	done := make(chan error, 1)
	go func() {
		done <- runQuestLoop(context.Background(), &out, &questOpts{
			now:    time.Now,
			store:  store,
			client: tmux.NewClient(runner),
		}, sessionID, questLoopRunOptions{
			MaxIters:       5,
			MaxTime:        5 * time.Second,
			StuckAfter:     3,
			BlockedTimeout: 20 * time.Millisecond,
		})
	}()
	waitForQuestLoopMarker(t, sessionID)
	writeLoopPaneState(t, sessionID, "blocked", 1)

	if err := waitLoopDone(t, done); err != nil {
		t.Fatalf("quest loop command: %v\noutput:\n%s", err, out.String())
	}
	got := out.String()
	for _, want := range []string{"blocked: agent is waiting for human input; loop paused", "terminal: stopped (blocked_timeout)", "last verdict: none"} {
		if !strings.Contains(got, want) {
			t.Fatalf("output missing %q:\n%s", want, got)
		}
	}
	if got := runner.sentCount(); got != 0 {
		t.Fatalf("blocked timeout injected %d message(s), want 0", got)
	}
}

func TestQuestLoopRefusesUnattachedAndInactive(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())

	saveQuest(t, "ACTIVE-1", quest.StatusActive, []quest.Gate{{Name: "tests", Type: quest.GateAuto, Check: "cmd:true"}})
	createManifest(t, store, "qm-free", "free", t.TempDir(), "standalone")
	if _, err := runCmdErr(t, store, newLoopCommandRunner("qm-free"), "quest", "loop", "qm-free", "--max-time", "1ms"); err == nil {
		t.Fatal("unattached session should be refused")
	}

	saveQuest(t, "WIP-1", quest.StatusWIP, []quest.Gate{{Name: "tests", Type: quest.GateAuto, Check: "cmd:true"}})
	createManifest(t, store, "qm-wip", "wip", t.TempDir(), "standalone")
	if err := state.StampQuest("qm-wip", "WIP-1"); err != nil {
		t.Fatalf("stamp wip quest: %v", err)
	}
	if _, err := runCmdErr(t, store, newLoopCommandRunner("qm-wip"), "quest", "loop", "qm-wip", "--max-time", "1ms"); err == nil {
		t.Fatal("inactive quest should be refused")
	}
}

func TestQuestLoopTargetUsesExplicitWorkerQuestAndCwd(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	workerCwd := t.TempDir()

	saveQuest(t, "WORKER-1", quest.StatusActive, []quest.Gate{{Name: "tests", Type: quest.GateAuto, Check: "cmd:true"}})
	createManifest(t, store, "qm-master", "master", t.TempDir(), "master")
	worker := state.Manifest{SessionID: "qm-worker", Title: "worker", Cwd: workerCwd}
	worker.SetExtra("parent_session", "qm-master")
	if err := store.Create(worker); err != nil {
		t.Fatalf("create worker manifest: %v", err)
	}
	if err := store.AddWorker("qm-master", "qm-worker"); err != nil {
		t.Fatalf("add worker: %v", err)
	}
	if err := state.StampQuest("qm-worker", "WORKER-1"); err != nil {
		t.Fatalf("stamp worker quest: %v", err)
	}

	target, err := resolveQuestLoopTarget("qm-worker", store)
	if err != nil {
		t.Fatalf("resolveQuestLoopTarget: %v", err)
	}
	if target.QuestID != "WORKER-1" {
		t.Fatalf("target quest id = %q, want WORKER-1", target.QuestID)
	}
	if target.Worktree != workerCwd {
		t.Fatalf("target worktree = %q, want worker cwd %q", target.Worktree, workerCwd)
	}
}

func TestQuestLoopRefusesQuestWithNoAutoGates(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	sessionID := "qm-toggle-only"
	questID := "TOGGLE-ONLY-1"

	saveQuest(t, questID, quest.StatusActive, []quest.Gate{
		{Name: "review", Type: quest.GateToggle, Before: quest.BeforePR},
		{Name: "ui-ok", Type: quest.GateToggle},
	})
	createManifest(t, store, sessionID, "toggle only", t.TempDir(), "standalone")
	if err := state.StampQuest(sessionID, questID); err != nil {
		t.Fatalf("stamp quest: %v", err)
	}

	_, err := runCmdErr(t, store, newLoopCommandRunner(sessionID), "quest", "loop", sessionID, "--max-time", "1ms")
	if err == nil {
		t.Fatal("toggle-only quest should be refused by quest loop")
	}
	if want := "quest TOGGLE-ONLY-1 has no auto gates to loop"; !strings.Contains(err.Error(), want) {
		t.Fatalf("error = %q, want %q", err, want)
	}
	if marker := loadQuestLoopMarker(t, sessionID); marker != nil {
		t.Fatalf("quest loop marker should not be armed: %+v", marker)
	}
}

func TestQuestLoopRefusesSecondArmUnlessForce(t *testing.T) {
	t.Setenv(quest.HomeEnv, t.TempDir())
	store := setupStore(t)
	t.Setenv(state.StateRootEnv, store.Root())
	sessionID := "qm-armed"

	saveQuest(t, "ARM-1", quest.StatusActive, []quest.Gate{{Name: "tests", Type: quest.GateAuto, Check: "cmd:true"}})
	createManifest(t, store, sessionID, "armed", t.TempDir(), "standalone")
	if err := state.StampQuest(sessionID, "ARM-1"); err != nil {
		t.Fatalf("stamp quest: %v", err)
	}
	if err := state.ArmQuestLoop(sessionID, time.Now(), false); err != nil {
		t.Fatalf("seed loop marker: %v", err)
	}

	if _, err := runCmdErr(t, store, newLoopCommandRunner(sessionID), "quest", "loop", sessionID, "--max-time", "1ms"); err == nil {
		t.Fatal("second arm should be refused")
	}
}

func saveQuest(t *testing.T, id string, status quest.Status, gates []quest.Gate) {
	t.Helper()
	q := &quest.Quest{ID: id, Title: id, Summary: "summary", Status: status, Gates: gates}
	if err := quest.DefaultStore().Save(q); err != nil {
		t.Fatalf("save quest %s: %v", id, err)
	}
}

type loopCommandRunner struct {
	sessionID string
	sends     chan string
	mu        sync.Mutex
	sent      []string
}

func newLoopCommandRunner(sessionID string) *loopCommandRunner {
	return &loopCommandRunner{sessionID: sessionID, sends: make(chan string, 8)}
}

func (r *loopCommandRunner) Run(_ context.Context, args ...string) (string, error) {
	if len(args) == 0 {
		return "", &tmux.ExitError{Code: 1}
	}
	switch args[0] {
	case "has-session":
		target := args[len(args)-1]
		if target == r.sessionID {
			return "", nil
		}
		return "", &tmux.ExitError{Code: 1}
	case "list-panes":
		return "0 1 primary", nil
	case "display-message":
		return "0", nil
	case "send-keys":
		if len(args) >= 2 && args[len(args)-1] != "Enter" {
			msg := args[len(args)-1]
			r.mu.Lock()
			r.sent = append(r.sent, msg)
			r.mu.Unlock()
			r.sends <- msg
		}
		return "", nil
	default:
		return "", &tmux.ExitError{Code: 1}
	}
}

func (r *loopCommandRunner) waitForSend(t *testing.T) string {
	t.Helper()
	select {
	case msg := <-r.sends:
		return msg
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for injected message")
		return ""
	}
}

func (r *loopCommandRunner) sentCount() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.sent)
}

func startQuestLoopCommand(t *testing.T, store *state.Store, runner tmux.Runner, args ...string) (*bytes.Buffer, <-chan error) {
	t.Helper()
	client := tmux.NewClient(runner)
	root := NewRootCmd(
		WithDeps(store, client),
	)
	var out bytes.Buffer
	root.SetOut(&out)
	root.SetErr(&bytes.Buffer{})
	root.SetArgs(args)
	done := make(chan error, 1)
	go func() {
		done <- root.Execute()
	}()
	return &out, done
}

func waitLoopDone(t *testing.T, done <-chan error) error {
	t.Helper()
	select {
	case err := <-done:
		return err
	case <-time.After(3 * time.Second):
		t.Fatal("quest loop command did not finish")
		return nil
	}
}

func waitForQuestLoopMarker(t *testing.T, sessionID string) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if loadQuestLoopMarker(t, sessionID) != nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out waiting for quest loop marker")
}

func loadQuestLoopMarker(t *testing.T, sessionID string) *state.QuestLoopState {
	t.Helper()
	ss, err := state.LoadSessionState(sessionID)
	if err != nil {
		t.Fatalf("load session state: %v", err)
	}
	if ss == nil {
		return nil
	}
	return ss.QuestLoop
}

func writeLoopPaneState(t *testing.T, sessionID, paneState string, seq int64) {
	t.Helper()
	if err := state.UpdateSessionState(sessionID, func(ss *state.SessionState) bool {
		ss.Panes["primary"] = state.PaneState{
			Role:      "primary",
			Agent:     "codex",
			State:     paneState,
			Seq:       seq,
			LastEvent: time.Unix(seq, 0).UTC(),
			LastKind:  "test",
		}
		return true
	}); err != nil {
		t.Fatalf("write pane state: %v", err)
	}
}

func readRelayInstruction(t *testing.T, pointer string) string {
	t.Helper()
	const prefix = "Read and follow the instructions in "
	const suffix = ". Act on them now, then report back with results."
	if !strings.HasPrefix(pointer, prefix) || !strings.HasSuffix(pointer, suffix) {
		return pointer
	}
	path := strings.TrimSuffix(strings.TrimPrefix(pointer, prefix), suffix)
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read relay file %s: %v", path, err)
	}
	return string(data)
}
