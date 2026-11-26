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

const inactivityThreshold = 30 * time.Minute

type alertEpisode struct {
	since   time.Time
	blocked bool
}

// Job runs under the daemon's jobs.lock; the hook state is its durable queue.
type Job struct {
	store     *state.Store
	router    *tmuxroute.Router
	send      func(context.Context, string, string) (message.Delivery, error)
	now       func() time.Time
	hasWork   atomic.Bool
	nextRow   int
	delivered map[string]alertEpisode // sent episodes awaiting their durable acknowledgement
}

func NewJob(store *state.Store, router *tmuxroute.Router) *Job {
	j := &Job{store: store, router: router, now: time.Now, delivered: make(map[string]alertEpisode)}
	j.send = message.NewServiceWithRouter(store, router).Notify
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
	// An empty worker set needs neither tmux nor a background-work lease. In
	// particular, a missing tmux binary must not keep an unused daemon alive.
	manifests, err := j.store.DiscoverSessions()
	if err != nil {
		return err
	}
	byID := make(map[string]state.Manifest, len(manifests))
	for _, m := range manifests {
		byID[m.SessionID] = m
	}
	registered := false
	for _, master := range manifests {
		if master.AgentSessionType() != "master" {
			continue
		}
		for _, id := range master.Workers {
			worker := byID[id]
			if worker.AgentSessionType() == "worker" && worker.ExtraString("parent_session") == master.SessionID {
				registered = true
				break
			}
		}
		if registered {
			break
		}
	}
	if !registered {
		j.hasWork.Store(false)
		clear(j.delivered)
		return nil
	}
	j.hasWork.Store(true)
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
	for id := range j.delivered {
		worker, ok := live[id]
		if !ok || !owners[worker.ExtraString("parent_session")+"\x00"+id] {
			delete(j.delivered, id)
		}
	}
	// Only live, registered workers are read. Historical state logs are never scanned.
	start := 0
	if len(inv.Rows) > 0 {
		start = j.nextRow % len(inv.Rows)
	}
	now := j.now()
	heldMasters := make(map[string]bool)
	for i := range inv.Rows {
		if err := ctx.Err(); err != nil {
			return err
		}
		index := (start + i) % len(inv.Rows)
		row := inv.Rows[index]
		// Advance before an operation can consume the rest of this pass's budget.
		j.nextRow = (index + 1) % len(inv.Rows)
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
		episode := pendingAlert(pane, now)
		if episode.since.IsZero() {
			delete(j.delivered, worker.SessionID)
			continue
		}
		if episode.blocked && pane.State != "blocked" {
			continue
		}
		delivered := j.delivered[worker.SessionID]
		if delivered.blocked != episode.blocked || !delivered.since.Equal(episode.since) {
			if heldMasters[parent] {
				continue
			}
			call, cancel := context.WithTimeout(ctx, 2*time.Second)
			delivery, err := j.send(call, parent, alertText(worker, pane, episode))
			cancel()
			if err != nil {
				errs = append(errs, fmt.Errorf("notify %s about %s: %w", parent, worker.SessionID, err))
				continue
			}
			if delivery == "" {
				heldMasters[parent] = true
			}
			if delivery != message.DeliveryAccepted && delivery != message.DeliverySubmitted {
				continue
			}
			j.delivered[worker.SessionID] = episode
		}
		var ackErr error
		if episode.blocked {
			ackErr = state.MarkBlockedAlertedAt(ctx, j.store.Root(), worker.SessionID, episode.since)
		} else {
			ackErr = state.MarkInactivityAlertedAt(ctx, j.store.Root(), worker.SessionID, episode.since)
		}
		if ackErr != nil {
			errs = append(errs, ackErr)
		} else {
			delete(j.delivered, worker.SessionID)
		}
	}
	// Keep monitoring while any managed worker is live.
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

func pendingAlert(pane state.PaneState, now time.Time) alertEpisode {
	if pane.HasBlockedEpisode() && !pane.BlockedAlerted {
		return alertEpisode{since: pane.BlockedSince, blocked: true}
	}
	if last := pane.WorkActivityAt(); !pane.InactivityAlerted && !last.IsZero() && now.Sub(last) >= inactivityThreshold {
		return alertEpisode{since: last}
	}
	return alertEpisode{}
}

func alertText(worker state.Manifest, pane state.PaneState, episode alertEpisode) string {
	if !episode.blocked {
		return fmt.Sprintf("[WORKER INACTIVE:%s] Worker %q is still marked working after at least %d minutes without reported activity.\nInspect with questmaster read %s.", worker.SessionID, worker.Title, inactivityThreshold/time.Minute, worker.SessionID)
	}
	text := fmt.Sprintf("[WORKER BLOCKED:%s] Worker %q needs attention.\n%s\nInspect with questmaster read %s. This is an automatic status alert; inspect the current dialog before answering it.", worker.SessionID, worker.Title, pane.Activity, worker.SessionID)
	if handle := worker.TmuxServer; handle != "" {
		text += fmt.Sprintf("\nIts tmux server is %q, session target %q; resolve the agent pane before interacting with it.", handle, tmux.SessionTarget(worker.SessionID))
	}
	return text
}
