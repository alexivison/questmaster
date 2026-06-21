package tui

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/session"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
)

var builtinAgentRegistry = func() *agent.Registry {
	registry, err := agent.NewRegistry(agent.DefaultConfig())
	if err != nil {
		return nil
	}
	return registry
}()

// TrackerActions defines the operations the tracker can perform.
type TrackerActions interface {
	Attach(ctx context.Context, currentID, targetID string) error
	Continue(ctx context.Context, sessionID string) error
	Relay(ctx context.Context, workerID, message string) error
	Broadcast(ctx context.Context, masterID, message string) (message.BroadcastResult, error)
	Spawn(ctx context.Context, masterID, title string) error
	Delete(ctx context.Context, masterID, workerID string) error
	SetDisplayColor(sessionID, color string) error
	SetRepoColor(repoIdentity, color string) error
	ManifestJSON(sessionID string) (string, error)
}

// liveTrackerActions implements TrackerActions using shared Go services.
type liveTrackerActions struct {
	sessionSvc *session.Service
	messageSvc *message.Service
	tmuxClient *tmux.Client
	store      *state.Store
	repoColors *state.RepoColorStore
}

// NewLiveTrackerActions creates a production TrackerActions backed by shared services.
func NewLiveTrackerActions(
	sessionSvc *session.Service,
	messageSvc *message.Service,
	tmuxClient *tmux.Client,
	store *state.Store,
) TrackerActions {
	return &liveTrackerActions{
		sessionSvc: sessionSvc,
		messageSvc: messageSvc,
		tmuxClient: tmuxClient,
		store:      store,
		repoColors: state.NewRepoColorStore(store.Root()),
	}
}

func (a *liveTrackerActions) Attach(ctx context.Context, currentID, targetID string) error {
	cmd := fmt.Sprintf("tmux switch-client -t %s", targetID)
	return a.tmuxClient.RunShell(ctx, currentID, cmd)
}

func (a *liveTrackerActions) Continue(ctx context.Context, sessionID string) error {
	if _, err := a.sessionSvc.Continue(ctx, sessionID); err != nil {
		return fmt.Errorf("continue %s: %w", sessionID, err)
	}
	return nil
}

func (a *liveTrackerActions) Relay(ctx context.Context, workerID, msg string) error {
	return a.messageSvc.Relay(ctx, workerID, msg)
}

func (a *liveTrackerActions) Broadcast(ctx context.Context, masterID, msg string) (message.BroadcastResult, error) {
	return a.messageSvc.Broadcast(ctx, masterID, msg)
}

func (a *liveTrackerActions) Spawn(ctx context.Context, masterID, title string) error {
	_, err := a.sessionSvc.Spawn(ctx, masterID, session.SpawnOpts{
		Title:    title,
		Detached: true,
	})
	return err
}

func (a *liveTrackerActions) Delete(ctx context.Context, masterID, workerID string) error {
	m, readErr := a.store.Read(workerID)
	if readErr == nil && m.SessionType == "master" {
		if err := a.sessionSvc.DeleteWorkers(ctx, workerID); err != nil {
			return fmt.Errorf("delete workers for %s: %w", workerID, err)
		}
	}
	isGhost := errors.Is(readErr, os.ErrNotExist)

	cmd := fmt.Sprintf("tmux kill-session -t %s 2>/dev/null; true", workerID)
	if err := a.tmuxClient.RunShell(ctx, workerID, cmd); err != nil {
		if err := a.sessionSvc.Delete(ctx, workerID); err != nil {
			return fmt.Errorf("delete %s: %w", workerID, err)
		}
	} else if !isGhost {
		if err := a.sessionSvc.Deregister(workerID); err != nil {
			return fmt.Errorf("deregister %s: %w", workerID, err)
		}
	}

	if isGhost {
		_ = a.store.RemoveWorker(masterID, workerID)
	}
	return nil
}

// SetDisplayColor updates only the named non-worker session's display color.
// Workers are tracker-colored from their parent master, so direct worker
// recolors are ignored. An empty color clears it so the session falls back to
// inherit/default, mirroring spawn-time semantics. The color is mutated in
// place so any unknown nested display.* keys (DisplayMetadata.Extra) survive
// the edit.
func (a *liveTrackerActions) SetDisplayColor(sessionID, color string) error {
	return a.store.SetDisplayColor(sessionID, color)
}

// SetRepoColor records (or, with an empty color, clears) the color of the repo
// identified by repoIdentity. A timestamp is stamped so the change competes
// with session colors on a last-write-wins basis. Lazily initialized so direct
// struct construction in tests works without a repo-color store.
func (a *liveTrackerActions) SetRepoColor(repoIdentity, color string) error {
	if a.repoColors == nil {
		a.repoColors = state.NewRepoColorStore(a.store.Root())
	}
	return a.repoColors.Set(repoIdentity, color)
}

func (a *liveTrackerActions) ManifestJSON(sessionID string) (string, error) {
	m, err := a.store.Read(sessionID)
	if err != nil {
		return "", fmt.Errorf("read manifest: %w", err)
	}
	pretty, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return "", fmt.Errorf("marshal manifest: %w", err)
	}
	return string(pretty), nil
}
