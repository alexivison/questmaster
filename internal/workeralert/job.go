//go:build linux || darwin

// Package workeralert notifies masters about workers waiting for attention.
package workeralert

import (
	"context"
	"errors"
	"fmt"
	"sync/atomic"
	"time"

	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

// Job runs under the daemon's jobs.lock; the hook state is its durable queue.
type Job struct {
	store   *state.Store
	router  *tmuxroute.Router
	send    func(context.Context, string, string) (message.Delivery, error)
	hasWork atomic.Bool
}

func NewJob(store *state.Store, router *tmuxroute.Router) *Job {
	j := &Job{store: store, router: router}
	j.send = message.NewServiceWithRouter(store, router).Notify
	j.hasWork.Store(true)
	return j
}

func (*Job) Name() string { return "worker-attention" }

func (j *Job) HasWork() bool { return j.hasWork.Load() }

func (j *Job) Run(ctx context.Context) error {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()
	for {
		pass, cancel := context.WithTimeout(ctx, 15*time.Second)
		err := j.step(pass)
		cancel()
		if err != nil {
			j.hasWork.Store(true)
			return err // the daemon logs and retries with its existing job backoff
		}
		select {
		case <-ctx.Done():
			return nil
		case <-ticker.C:
		}
	}
}

func (j *Job) step(ctx context.Context) error {
	if j.router == nil {
		return fmt.Errorf("tmux router is required for worker alerts")
	}
	inv := j.router.Inventory(ctx)
	live := make(map[string]state.Manifest, len(inv.Rows))
	owners := make(map[string]bool)
	var errs []error
	for _, server := range inv.Servers {
		if server.Outcome == tmuxroute.Unavailable {
			errs = append(errs, fmt.Errorf("tmux server %s unavailable: %s", server.Label, server.Error))
		}
	}
	for _, row := range inv.Rows {
		if err := ctx.Err(); err != nil {
			return err
		}
		if row.Conflict || !state.IsValidSessionID(row.ID) {
			continue
		}
		m, err := j.store.Read(row.ID)
		if err != nil {
			continue // plain tmux sessions have no manifest
		}
		if string(m.TmuxServer) != row.Label {
			continue
		}
		live[row.ID] = m
	}
	for _, m := range live {
		if m.AgentSessionType() == "master" {
			for _, worker := range m.Workers {
				if _, ok := live[worker]; ok {
					owners[m.SessionID+"\x00"+worker] = true
				}
			}
		}
	}
	// Only live, registered workers are read. Historical state logs are never scanned.
	for _, row := range inv.Rows {
		if err := ctx.Err(); err != nil {
			return err
		}
		worker, ok := live[row.ID]
		parent := worker.ExtraString("parent_session")
		if !ok || worker.AgentSessionType() != "worker" || !owners[parent+"\x00"+row.ID] {
			continue
		}
		ss, err := state.LoadSessionStateAt(j.store.Root(), worker.SessionID)
		if err != nil {
			errs = append(errs, err)
			continue
		}
		if ss == nil {
			continue
		}
		pane := ss.Panes["agent"]
		if pane.State != "blocked" || pane.BlockedSince.IsZero() || pane.BlockedAlerted {
			continue
		}
		call, cancel := context.WithTimeout(ctx, 2*time.Second)
		delivery, err := j.send(call, parent, alertText(worker, pane))
		cancel()
		if err != nil {
			errs = append(errs, fmt.Errorf("notify %s about %s: %w", parent, worker.SessionID, err))
			continue
		}
		if delivery == message.DeliveryAccepted || delivery == message.DeliverySubmitted {
			if err := state.MarkBlockedAlertedAt(ctx, j.store.Root(), worker.SessionID, pane.BlockedSince); err != nil {
				errs = append(errs, err)
			}
		}
	}
	// Keep monitoring while any managed worker is live, even between blocked episodes.
	hasWorkers := false
	for id, worker := range live {
		if worker.AgentSessionType() == "worker" && owners[worker.ExtraString("parent_session")+"\x00"+id] {
			hasWorkers = true
			break
		}
	}
	j.hasWork.Store(hasWorkers || len(errs) > 0)
	return errors.Join(errs...)
}

func alertText(worker state.Manifest, pane state.PaneState) string {
	text := fmt.Sprintf("[WORKER BLOCKED:%s] Worker %q needs attention.\n%s\nInspect with questmaster read %s. This is an automatic status alert; inspect the current dialog before answering it.", worker.SessionID, worker.Title, pane.Activity, worker.SessionID)
	if handle := worker.TmuxServer; handle != "" {
		text += fmt.Sprintf("\nIts tmux server is %q, session target %q; resolve the agent pane before interacting with it.", handle, tmux.SessionTarget(worker.SessionID))
	}
	return text
}
