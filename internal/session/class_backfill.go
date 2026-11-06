//go:build linux || darwin

package session

import (
	"context"
	"errors"
	"fmt"
	"math/rand/v2"
	"sync/atomic"
	"time"

	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tmuxroute"
)

const classBackfillRescanInterval = 10 * time.Minute

// ClassBackfillJob assigns display classes to existing master manifests.
type ClassBackfillJob struct {
	store          *state.Store
	tmuxClient     *tmux.Client
	router         *tmuxroute.Router
	randomIndex    func(int) int
	rescanInterval time.Duration
	hasWork        atomic.Bool
}

// NewClassBackfillJob creates the daemon job with production random selection.
func NewClassBackfillJob(store *state.Store, tmuxClient *tmux.Client, routers ...*tmuxroute.Router) *ClassBackfillJob {
	var router *tmuxroute.Router
	if len(routers) > 0 {
		router = routers[0]
	}
	job := &ClassBackfillJob{
		store:          store,
		tmuxClient:     tmuxClient,
		router:         router,
		randomIndex:    rand.IntN,
		rescanInterval: classBackfillRescanInterval,
	}
	job.hasWork.Store(true)
	return job
}

func (j *ClassBackfillJob) Name() string { return "session-class-backfill" }

func (j *ClassBackfillJob) HasWork() bool {
	return j.hasWork.Load()
}

func (j *ClassBackfillJob) Run(ctx context.Context) error {
	for {
		if ctx.Err() != nil {
			return nil
		}
		if err := j.runPass(ctx); err != nil {
			j.hasWork.Store(true)
			return err
		}
		j.hasWork.Store(false)

		timer := time.NewTimer(j.rescanInterval)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil
		case <-timer.C:
		}
	}
}

func (j *ClassBackfillJob) runPass(ctx context.Context) error {
	if j.router == nil {
		return fmt.Errorf("tmux router is required for class backfill")
	}
	manifests, err := j.store.DiscoverSessions()
	if err != nil {
		return fmt.Errorf("discover sessions for class backfill: %w", err)
	}
	hasClasslessMaster := false
	for _, manifest := range manifests {
		if manifest.AgentSessionType() == "master" && manifest.DisplayClass() == "" {
			hasClasslessMaster = true
			break
		}
	}
	if !hasClasslessMaster {
		return nil
	}
	j.hasWork.Store(true)
	liveSessions, activeClasses, err := routedLiveMasterClasses(ctx, j.store, j.router)
	if err != nil {
		return fmt.Errorf("list live sessions for class backfill: %w", err)
	}

	var writeErrors []error
	for _, manifest := range manifests {
		if err := ctx.Err(); err != nil {
			return err
		}
		if manifest.AgentSessionType() != "master" || manifest.DisplayClass() != "" {
			continue
		}
		class := state.ChooseSessionClass(activeClasses, j.randomIndex)
		stored, err := j.store.SetSessionClassIfMissing(manifest.SessionID, class)
		if err != nil {
			writeErrors = append(writeErrors, fmt.Errorf("%s: %w", manifest.SessionID, err))
			continue
		}
		if _, live := liveSessions[manifest.SessionID]; live {
			activeClasses = append(activeClasses, stored)
		}
	}
	if len(writeErrors) > 0 {
		return fmt.Errorf("backfill session classes (%d write failures): %w", len(writeErrors), errors.Join(writeErrors...))
	}
	return nil
}

// liveMasterClasses is the explicit creation-server-only class-balancing path.
// It does not delete state or decide whether any existing session is stopped.
func liveMasterClasses(ctx context.Context, store *state.Store, tmuxClient *tmux.Client) (map[string]struct{}, []string, error) {
	if tmuxClient == nil {
		return nil, nil, fmt.Errorf("tmux client is required")
	}
	router := tmuxroute.New(store, map[string]*tmux.Client{"default": tmuxClient}, func() string { return "default" }, nil)
	return routedLiveMasterClasses(ctx, store, router)
}

func routedLiveMasterClasses(ctx context.Context, store *state.Store, router *tmuxroute.Router) (map[string]struct{}, []string, error) {
	if store == nil {
		return nil, nil, fmt.Errorf("state store is required")
	}
	if router == nil {
		return nil, nil, fmt.Errorf("tmux router is required for class backfill")
	}
	inv := router.Inventory(ctx)
	for _, server := range inv.Servers {
		if server.Outcome == tmuxroute.Unavailable {
			return nil, nil, fmt.Errorf("tmux server %s unavailable: %s", server.Label, server.Error)
		}
	}
	liveSessions := make(map[string]struct{}, len(inv.Rows))
	activeClasses := make([]string, 0, len(inv.Rows))
	for _, row := range inv.Rows {
		sessionID := row.ID
		if !state.IsValidSessionID(sessionID) {
			continue
		}
		manifest, err := store.Read(sessionID)
		if err != nil {
			continue
		}
		handle, err := router.Route(manifest)
		if err != nil {
			return nil, nil, err
		}
		if handle.Label() != row.Label {
			continue
		}
		liveSessions[sessionID] = struct{}{}
		if manifest.AgentSessionType() != "master" {
			continue
		}
		if class := manifest.DisplayClass(); class != "" {
			activeClasses = append(activeClasses, class)
		}
	}
	return liveSessions, activeClasses, nil
}
