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
)

const classBackfillRescanInterval = 10 * time.Minute

// ClassBackfillJob assigns display classes to existing master manifests.
type ClassBackfillJob struct {
	store          *state.Store
	tmuxClient     *tmux.Client
	randomIndex    func(int) int
	rescanInterval time.Duration
	hasWork        atomic.Bool
}

// NewClassBackfillJob creates the daemon job with production random selection.
func NewClassBackfillJob(store *state.Store, tmuxClient *tmux.Client) *ClassBackfillJob {
	job := &ClassBackfillJob{
		store:          store,
		tmuxClient:     tmuxClient,
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
	liveSessions, activeClasses, err := liveMasterClasses(ctx, j.store, j.tmuxClient)
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

func liveMasterClasses(ctx context.Context, store *state.Store, tmuxClient *tmux.Client) (map[string]struct{}, []string, error) {
	if store == nil {
		return nil, nil, fmt.Errorf("state store is required")
	}
	if tmuxClient == nil {
		return nil, nil, fmt.Errorf("tmux client is required")
	}
	liveSessionIDs, err := tmuxClient.ListSessions(ctx)
	if err != nil {
		return nil, nil, err
	}
	liveSessions := make(map[string]struct{}, len(liveSessionIDs))
	activeClasses := make([]string, 0, len(liveSessionIDs))
	for _, sessionID := range liveSessionIDs {
		if !state.IsValidSessionID(sessionID) {
			continue
		}
		liveSessions[sessionID] = struct{}{}
		manifest, err := store.Read(sessionID)
		if err != nil || manifest.AgentSessionType() != "master" {
			continue
		}
		if class := manifest.DisplayClass(); class != "" {
			activeClasses = append(activeClasses, class)
		}
	}
	return liveSessions, activeClasses, nil
}
