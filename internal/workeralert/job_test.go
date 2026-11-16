//go:build linux || darwin

package workeralert

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

var blockedAt = time.Date(2026, 1, 2, 3, 4, 5, 0, time.UTC)

type alertRunner struct {
	live  []string
	sends []string
	err   error
}

func (r *alertRunner) Run(_ context.Context, args ...string) (string, error) {
	switch args[0] {
	case "list-sessions":
		return strings.Join(r.live, "\n"), r.err
	case "has-session":
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
			j.send = func(context.Context, string, string) (message.Delivery, error) {
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
