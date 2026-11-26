//go:build linux || darwin

package workeralert

import (
	"context"
	"errors"
	"fmt"
	"os"
	"runtime"
	"slices"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

var blockedAt = time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)

type alertRunner struct {
	live   []string
	sends  []string
	err    error
	lists  int
	checks int
	before func([]string)
}

func (r *alertRunner) Run(_ context.Context, args ...string) (string, error) {
	if r.before != nil {
		r.before(args)
	}
	switch args[0] {
	case "list-sessions":
		r.lists++
		return strings.Join(r.live, "\n"), r.err
	case "has-session":
		r.checks++
		id := strings.TrimSuffix(strings.TrimPrefix(args[2], "="), ":")
		if !slices.Contains(r.live, id) {
			return "", &tmux.ExitError{Code: 1}
		}
		return "", nil
	case "list-panes":
		return "0 0 agent", nil
	case "list-clients":
		return "", nil
	case "display-message":
		if args[len(args)-1] == "#{pane_in_mode}" {
			return "0", nil
		}
		return "%12\t0", nil
	case "send-keys":
		if args[len(args)-1] != "Enter" {
			r.sends = append(r.sends, args[len(args)-1])
		}
		return "", nil
	default:
		return "", fmt.Errorf("unexpected tmux command %v", args)
	}
}

func newAlertFixture(t *testing.T) (*Job, *alertRunner) {
	t.Helper()
	store, err := state.NewStore(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	master := state.Manifest{SessionID: "qm-master", TmuxServer: "dev_previous", Workers: []string{"qm-worker"}, Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}
	worker := state.Manifest{SessionID: "qm-worker", TmuxServer: "questmaster", Title: "Parser fix", Agents: []state.AgentManifest{{Name: "claude", Role: "agent"}}}
	worker.SetExtra("parent_session", master.SessionID)
	for _, m := range []state.Manifest{master, worker} {
		if err := store.Create(m); err != nil {
			t.Fatal(err)
		}
	}
	masterRunner := &alertRunner{live: []string{master.SessionID}}
	workerRunner := &alertRunner{live: []string{worker.SessionID}}
	router := tmuxroute.New(store, map[string]*tmux.Client{
		"dev_previous": tmux.NewClient(masterRunner),
		"questmaster":  tmux.NewClient(workerRunner),
	}, func() string { return "questmaster" }, nil)
	j := NewJob(store, router)
	writePane(t, store.Root(), master.SessionID, state.PaneState{State: "idle", Role: "agent"})
	writePane(t, store.Root(), worker.SessionID, state.PaneState{State: "blocked", Role: "agent", Activity: "Question: Skip invalid entries?", BlockedSince: blockedAt})
	return j, masterRunner
}

func writePane(t *testing.T, root, id string, pane state.PaneState) {
	t.Helper()
	err := state.UpdateAndLogAt(root, id, &state.StateEvent{Ts: blockedAt, Action: "test"}, func(ss *state.SessionState) bool {
		ss.Panes["agent"] = pane
		return true
	})
	if err != nil {
		t.Fatal(err)
	}
}

func loadPane(t *testing.T, root, id string) state.PaneState {
	t.Helper()
	ss, err := state.LoadSessionStateAt(root, id)
	if err != nil || ss == nil {
		t.Fatalf("load %s: %v", id, err)
	}
	return ss.Panes["agent"]
}

func step(t *testing.T, j *Job) {
	t.Helper()
	if err := j.step(t.Context()); err != nil {
		t.Fatal(err)
	}
}

func TestAlertsUseRecordedMasterRouteAndSurviveRestart(t *testing.T) {
	t.Parallel()
	j, runner := newAlertFixture(t)
	step(t, j)
	if len(runner.sends) != 1 {
		t.Fatalf("sends = %v, want one on the master's recorded server", runner.sends)
	}
	for _, want := range []string{"[WORKER BLOCKED:qm-worker]", "Parser fix", "Question: Skip invalid entries?", `"questmaster"`, `"=qm-worker:"`} {
		if !strings.Contains(runner.sends[0], want) {
			t.Errorf("alert missing %q: %s", want, runner.sends[0])
		}
	}
	if !loadPane(t, j.store.Root(), "qm-worker").BlockedAlerted {
		t.Fatal("accepted alert was not acknowledged")
	}
	step(t, NewJob(j.store, j.router))
	if len(runner.sends) != 1 {
		t.Fatal("restarting the job repeated the delivered alert")
	}
	if !j.HasWork() {
		t.Fatal("live workers must keep attention monitoring active")
	}
}

func TestInactivityAlertUsesLatestWorkAndOnlySendsOnce(t *testing.T) {
	t.Parallel()
	j, runner := newAlertFixture(t)
	root := j.store.Root()
	worker := state.PaneState{
		State: "working", LastEvent: blockedAt.Add(-time.Hour), WorkingSince: blockedAt.Add(-time.Hour),
		LastWorkActivity: blockedAt, RunningTools: []state.RunningTool{{Tool: "Bash", StartedAt: blockedAt}},
	}
	writePane(t, root, "qm-worker", worker)
	now := blockedAt.Add(30*time.Minute - time.Nanosecond)
	clock := func() time.Time { return now }
	j.now = clock
	step(t, j)
	if len(runner.sends) != 0 {
		t.Fatalf("alerted before 30 minutes without activity: %v", runner.sends)
	}
	now = now.Add(time.Nanosecond)
	step(t, j)
	if len(runner.sends) != 1 || !loadPane(t, root, "qm-worker").InactivityAlerted {
		t.Fatalf("expected one acknowledged inactivity alert, got %v", runner.sends)
	}
	for _, want := range []string{"[WORKER INACTIVE:qm-worker]", "Parser fix", "30 minutes", "questmaster read qm-worker"} {
		if !strings.Contains(runner.sends[0], want) {
			t.Errorf("alert missing %q: %s", want, runner.sends[0])
		}
	}
	j = NewJob(j.store, j.router)
	j.now = clock
	now = now.Add(time.Hour)
	step(t, j)
	if len(runner.sends) != 1 {
		t.Fatalf("the same inactivity alerted again after restart: %v", runner.sends)
	}
}

func TestInactivityAlertWaitsForMasterAndRechecksWorker(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"still inactive", "new activity", "done", "blocked with subagent working"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			j, runner := newAlertFixture(t)
			root := j.store.Root()
			now := blockedAt.Add(inactivityThreshold)
			j.now = func() time.Time { return now }
			// A worker already running when the daemon upgrades has only LastEvent.
			worker := state.PaneState{State: "working", LastEvent: blockedAt}
			writePane(t, root, "qm-worker", worker)
			writePane(t, root, "qm-master", state.PaneState{State: "working"})
			step(t, j)
			if len(runner.sends) != 0 || loadPane(t, root, "qm-worker").InactivityAlerted {
				t.Fatal("busy master received or acknowledged an inactivity alert")
			}
			switch scenario {
			case "new activity":
				worker.LastWorkActivity = now
			case "done":
				worker.State = "done"
			case "blocked with subagent working":
				worker.BlockedSince = blockedAt
				worker.SubagentWake = &state.SubagentWake{State: "blocked", IDs: []string{"child"}}
			}
			writePane(t, root, "qm-worker", worker)
			writePane(t, root, "qm-master", state.PaneState{State: "done"})
			step(t, j)
			want := 0
			if scenario == "still inactive" {
				want = 1
			}
			if len(runner.sends) != want {
				t.Fatalf("inactivity alerts = %v, want %d", runner.sends, want)
			}
		})
	}
}

func TestInactivityAcknowledgementDoesNotSuppressNewEpisode(t *testing.T) {
	t.Parallel()
	j, _ := newAlertFixture(t)
	root := j.store.Root()
	now := blockedAt.Add(inactivityThreshold)
	j.now = func() time.Time { return now }
	worker := state.PaneState{State: "working", LastWorkActivity: blockedAt}
	writePane(t, root, "qm-worker", worker)
	sends := 0
	j.send = func(context.Context, string, string, func() error) (message.Delivery, error) {
		sends++
		if sends == 1 {
			worker.LastWorkActivity = now
			writePane(t, root, "qm-worker", worker)
		}
		return message.DeliveryAccepted, nil
	}
	step(t, j)
	if loadPane(t, root, "qm-worker").InactivityAlerted {
		t.Fatal("delivery of the old alert acknowledged newer activity")
	}
	now = now.Add(inactivityThreshold)
	step(t, j)
	if sends != 2 || !loadPane(t, root, "qm-worker").InactivityAlerted {
		t.Fatalf("expected the next inactivity episode to alert, got %d sends", sends)
	}
}

func TestWorkerResumingDuringReadinessDiscardsAlert(t *testing.T) {
	t.Parallel()
	for _, tc := range []struct {
		name       string
		inactivity bool
		resumeOn   string
	}{
		{"inactivity during master liveness check", true, "has-session"},
		{"blocked during master pane idle check", false, "#{pane_in_mode}"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			j, runner := newAlertFixture(t)
			now := blockedAt.Add(inactivityThreshold)
			j.now = func() time.Time { return now }
			root := j.store.Root()
			if tc.inactivity {
				writePane(t, root, "qm-worker", state.PaneState{State: "working", LastWorkActivity: blockedAt})
			}
			resumed := false
			runner.before = func(args []string) {
				if !resumed && (args[0] == tc.resumeOn || args[len(args)-1] == tc.resumeOn) {
					writePane(t, root, "qm-worker", state.PaneState{State: "working", LastWorkActivity: now})
					resumed = true
				}
			}
			step(t, j)
			if !resumed || len(runner.sends) != 0 {
				t.Fatalf("worker resumed = %t, stale alerts sent = %v", resumed, runner.sends)
			}
		})
	}
}

func TestHeldInactivityAlertsCheckBusyMasterOncePerPass(t *testing.T) {
	t.Parallel()
	j, masterRunner := newAlertFixture(t)
	const parent, first, second = "qm-master", "qm-worker", "qm-second"
	worker := state.Manifest{SessionID: second, TmuxServer: "questmaster", Agents: []state.AgentManifest{{Name: "claude", Role: "agent"}}}
	worker.SetExtra("parent_session", parent)
	if err := j.store.Create(worker); err != nil {
		t.Fatal(err)
	}
	if err := j.store.AddWorker(parent, second); err != nil {
		t.Fatal(err)
	}
	router := tmuxroute.New(j.store, map[string]*tmux.Client{
		"dev_previous": tmux.NewClient(masterRunner),
		"questmaster":  tmux.NewClient(&alertRunner{live: []string{first, second}}),
	}, func() string { return "questmaster" }, nil)
	j = NewJob(j.store, router)
	j.now = func() time.Time { return blockedAt.Add(inactivityThreshold) }
	root := j.store.Root()
	for _, id := range []string{first, second} {
		writePane(t, root, id, state.PaneState{State: "working", LastWorkActivity: blockedAt})
	}
	writePane(t, root, parent, state.PaneState{State: "working"})
	for pass := 1; pass <= 2; pass++ {
		step(t, j)
		if masterRunner.checks != pass || len(masterRunner.sends) != 0 {
			t.Fatalf("busy master after pass %d: checks=%d, sends=%v", pass, masterRunner.checks, masterRunner.sends)
		}
	}
	writePane(t, root, parent, state.PaneState{State: "idle"})
	step(t, j)
	if len(masterRunner.sends) != 2 {
		t.Fatalf("expected both pending alerts when the master became idle, got %v", masterRunner.sends)
	}
}

func TestBusyMasterKeepsPendingAlertAcrossRestart(t *testing.T) {
	t.Parallel()
	j, runner := newAlertFixture(t)
	writePane(t, j.store.Root(), "qm-master", state.PaneState{State: "working", Role: "agent"})
	step(t, j)
	if len(runner.sends) != 0 || loadPane(t, j.store.Root(), "qm-worker").BlockedAlerted {
		t.Fatal("busy master received or acknowledged the pending alert")
	}
	writePane(t, j.store.Root(), "qm-master", state.PaneState{State: "done", Role: "agent"})
	step(t, NewJob(j.store, j.router))
	if len(runner.sends) != 1 {
		t.Fatal("pending alert was lost when the job restarted")
	}
}

func TestPendingAlertExpiresWhenWorkerResumes(t *testing.T) {
	t.Parallel()
	j, runner := newAlertFixture(t)
	writePane(t, j.store.Root(), "qm-master", state.PaneState{State: "working", Role: "agent"})
	step(t, j)
	writePane(t, j.store.Root(), "qm-worker", state.PaneState{State: "done", Role: "agent"})
	writePane(t, j.store.Root(), "qm-master", state.PaneState{State: "done", Role: "agent"})
	step(t, NewJob(j.store, j.router))
	if len(runner.sends) != 0 {
		t.Fatal("an alert outlived its blocked episode")
	}
}

func TestResolvedOrUnownedWorkersDoNotAlert(t *testing.T) {
	t.Parallel()
	for _, change := range []string{"resolved", "closed worker", "closed master", "wrong parent", "deregistered", "wrong server", "conflicting session"} {
		t.Run(change, func(t *testing.T) {
			t.Parallel()
			j, runner := newAlertFixture(t)
			switch change {
			case "resolved":
				pane := loadPane(t, j.store.Root(), "qm-worker")
				pane.State = "working"
				writePane(t, j.store.Root(), "qm-worker", pane)
			case "closed worker":
				j.router = tmuxroute.New(j.store, map[string]*tmux.Client{"dev_previous": tmux.NewClient(runner), "questmaster": tmux.NewClient(&alertRunner{})}, func() string { return "questmaster" }, nil)
			case "closed master":
				runner.live = nil
			case "wrong parent":
				if err := j.store.Update("qm-worker", func(m *state.Manifest) { m.SetExtra("parent_session", "qm-other") }); err != nil {
					t.Fatal(err)
				}
			case "deregistered":
				if err := j.store.RemoveWorker("qm-master", "qm-worker"); err != nil {
					t.Fatal(err)
				}
			case "wrong server":
				if err := j.store.Update("qm-worker", func(m *state.Manifest) { m.TmuxServer = "dev_previous" }); err != nil {
					t.Fatal(err)
				}
			case "conflicting session":
				runner.live = append(runner.live, "qm-worker")
			}
			step(t, j)
			if len(runner.sends) != 0 {
				t.Fatalf("stale or unrelated worker alerted: %v", runner.sends)
			}
			if (change == "closed worker" || change == "closed master") && j.HasWork() {
				t.Fatal("stopped sessions kept worker attention monitoring alive")
			}
		})
	}
}

func TestDeliveryFailureRetriesAndCannotAcknowledgeNewerBlock(t *testing.T) {
	t.Parallel()
	for _, result := range []message.Delivery{message.DeliveryAccepted, message.DeliverySubmitted} {
		t.Run(string(result), func(t *testing.T) {
			t.Parallel()
			j, _ := newAlertFixture(t)
			calls := 0
			j.send = func(context.Context, string, string, func() error) (message.Delivery, error) {
				calls++
				if calls == 1 {
					return "", errors.New("temporary transport failure")
				}
				if calls == 2 {
					pane := loadPane(t, j.store.Root(), "qm-worker")
					pane.BlockedSince = blockedAt.Add(time.Minute)
					writePane(t, j.store.Root(), "qm-worker", pane)
				}
				return result, nil
			}
			if err := j.step(t.Context()); err == nil {
				t.Fatal("transport failure was not surfaced")
			}
			if loadPane(t, j.store.Root(), "qm-worker").BlockedAlerted {
				t.Fatal("failed delivery acknowledged the alert")
			}
			step(t, j)
			if loadPane(t, j.store.Root(), "qm-worker").BlockedAlerted {
				t.Fatal("delivery of the old episode acknowledged the new block")
			}
			step(t, j)
			if calls != 3 || !loadPane(t, j.store.Root(), "qm-worker").BlockedAlerted {
				t.Fatalf("new episode: calls=%d", calls)
			}
		})
	}
}

func TestUnavailableInventoryRetainsMonitoring(t *testing.T) {
	t.Parallel()
	j, runner := newAlertFixture(t)
	runner.err = errors.New("server unavailable")
	if err := j.step(t.Context()); err == nil || !j.HasWork() {
		t.Fatalf("unavailable inventory: err=%v, hasWork=%v", err, j.HasWork())
	}
	if len(runner.sends) != 0 {
		t.Fatal("alert sent without a live master")
	}
}

func TestEmptyWorkerSetDoesNotRequireTmux(t *testing.T) {
	t.Parallel()
	for _, scenario := range []string{"empty root", "master only", "orphan worker", "deregistered worker"} {
		t.Run(scenario, func(t *testing.T) {
			t.Parallel()
			j, runner := newAlertFixture(t)
			switch scenario {
			case "empty root":
				if err := j.store.Delete("qm-master"); err != nil {
					t.Fatal(err)
				}
				fallthrough
			case "master only":
				if err := j.store.Delete("qm-worker"); err != nil {
					t.Fatal(err)
				}
			case "orphan worker":
				if err := j.store.Delete("qm-master"); err != nil {
					t.Fatal(err)
				}
			case "deregistered worker":
				if err := j.store.RemoveWorker("qm-master", "qm-worker"); err != nil {
					t.Fatal(err)
				}
			}
			runner.err = errors.New("tmux unavailable")
			step(t, j)
			if runner.lists != 0 || j.HasWork() {
				t.Fatalf("empty worker set: tmux probes=%d, hasWork=%v", runner.lists, j.HasWork())
			}
		})
	}
}

func TestSlowFailuresDoNotStarveAnotherMaster(t *testing.T) {
	t.Parallel()
	j, masterRunner := newAlertFixture(t)
	other := state.Manifest{SessionID: "qm-other", TmuxServer: "dev_previous", Workers: []string{"qm-healthy"}, Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}
	worker := state.Manifest{SessionID: "qm-healthy", TmuxServer: "questmaster", Agents: []state.AgentManifest{{Name: "codex", Role: "agent"}}}
	worker.SetExtra("parent_session", other.SessionID)
	for _, m := range []state.Manifest{other, worker} {
		if err := j.store.Create(m); err != nil {
			t.Fatal(err)
		}
	}
	masterRunner.live = append(masterRunner.live, other.SessionID)
	writePane(t, j.store.Root(), worker.SessionID, state.PaneState{State: "blocked", BlockedSince: blockedAt})
	j.router = tmuxroute.New(j.store, map[string]*tmux.Client{
		"dev_previous": tmux.NewClient(masterRunner),
		"questmaster":  tmux.NewClient(&alertRunner{live: []string{"qm-worker", worker.SessionID}}),
	}, func() string { return "questmaster" }, nil)
	var cancelPass context.CancelFunc
	healthy := 0
	j.send = func(ctx context.Context, parent, _ string, _ func() error) (message.Delivery, error) {
		if parent == other.SessionID {
			healthy++
			return message.DeliveryAccepted, nil
		}
		// Model a slow transport consuming the remaining pass budget, without a clock wait.
		cancelPass()
		return "", ctx.Err()
	}
	for range 2 {
		ctx, cancel := context.WithCancel(t.Context())
		cancelPass = cancel
		err := j.step(ctx)
		cancel()
		if err == nil {
			t.Fatal("expected the failed transport to cancel the pass")
		}
	}
	if healthy != 1 {
		t.Fatalf("healthy master attempts=%d, want one despite earlier failures", healthy)
	}
}

func TestContendedAcknowledgementDoesNotResendOrRetainWaiters(t *testing.T) {
	// Serial: the goroutine count observes only this cancelled-lock scenario.
	j, _ := newAlertFixture(t)
	lock, err := os.OpenFile(state.SessionStateLockPath(j.store.Root(), "qm-worker"), os.O_RDWR, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatal(err)
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN) //nolint:errcheck
	sends := 0
	j.send = func(context.Context, string, string, func() error) (message.Delivery, error) {
		sends++
		return message.DeliverySubmitted, nil
	}
	base := t.Context()
	before := runtime.NumGoroutine()
	for range 5 {
		ctx, cancel := context.WithTimeout(base, 50*time.Millisecond)
		err := j.step(ctx)
		cancel()
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("held lock error=%v, want a bounded acknowledgement wait", err)
		}
	}
	if after := runtime.NumGoroutine(); after > before+2 {
		t.Fatalf("cancelled acknowledgements retained goroutines: before=%d after=%d", before, after)
	}
	if sends != 1 || len(j.delivered) != 1 {
		t.Fatalf("pending acknowledgement: sends=%d retained=%d, want one of each", sends, len(j.delivered))
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_UN); err != nil {
		t.Fatal(err)
	}
	step(t, j)
	if sends != 1 || len(j.delivered) != 0 || !loadPane(t, j.store.Root(), "qm-worker").BlockedAlerted {
		t.Fatal("the delivered episode was resent or its acknowledgement did not recover")
	}
	if err := j.store.RemoveWorker("qm-master", "qm-worker"); err != nil {
		t.Fatal(err)
	}
	j.delivered["qm-worker"] = alertEpisode{since: blockedAt, blocked: true}
	step(t, j)
	if len(j.delivered) != 0 {
		t.Fatal("deregistered workers retained acknowledgement state")
	}
}

func TestAcknowledgementSurvivesSubagentWakeDuringDelivery(t *testing.T) {
	t.Parallel()
	j, _ := newAlertFixture(t)
	sends := 0
	j.send = func(context.Context, string, string, func() error) (message.Delivery, error) {
		sends++
		pane := loadPane(t, j.store.Root(), "qm-worker")
		pane.SubagentWake = &state.SubagentWake{State: "blocked", Activity: pane.Activity, IDs: []string{"child-1"}}
		pane.State = "working"
		writePane(t, j.store.Root(), "qm-worker", pane)
		return message.DeliveryAccepted, nil
	}
	step(t, j)
	pane := loadPane(t, j.store.Root(), "qm-worker")
	if !pane.BlockedAlerted || !pane.BlockedSince.Equal(blockedAt) {
		t.Fatalf("subagent wake lost an in-flight acknowledgement: %+v", pane)
	}
	pane.State, pane.SubagentWake = "blocked", nil
	writePane(t, j.store.Root(), "qm-worker", pane)
	step(t, j)
	if sends != 1 {
		t.Fatal("the unanswered dialog was alerted again after subagent work")
	}
}
