package tui

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"

	"github.com/anthropics/ai-config/tools/party-cli/internal/message"
	"github.com/anthropics/ai-config/tools/party-cli/internal/session"
	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// TrackerActions defines the operations the tracker can perform.
type TrackerActions interface {
	Attach(ctx context.Context, masterID, workerID string) error
	Relay(ctx context.Context, workerID, message string) error
	Broadcast(ctx context.Context, masterID, message string) error
	Spawn(ctx context.Context, masterID, title string) error
	Stop(ctx context.Context, masterID, workerID string) error
	Delete(ctx context.Context, masterID, workerID string) error
	ManifestJSON(sessionID string) (string, error)
}

// liveTrackerActions implements TrackerActions using shared Go services.
type liveTrackerActions struct {
	sessionSvc *session.Service
	messageSvc *message.Service
	tmuxClient *tmux.Client
	store      *state.Store
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
	}
}

func (a *liveTrackerActions) Attach(ctx context.Context, masterID, workerID string) error {
	// Can't use switch-client from inside a pane (no client context, list-clients
	// returns empty). Instead, use run-shell which executes in the tmux server
	// context where the client IS visible.
	cmd := fmt.Sprintf("tmux switch-client -t %s", workerID)
	return a.tmuxClient.RunShell(ctx, masterID, cmd)
}

func (a *liveTrackerActions) Relay(ctx context.Context, workerID, msg string) error {
	return a.messageSvc.Relay(ctx, workerID, msg)
}

func (a *liveTrackerActions) Broadcast(ctx context.Context, masterID, msg string) error {
	_, err := a.messageSvc.Broadcast(ctx, masterID, msg)
	return err
}

func (a *liveTrackerActions) Spawn(ctx context.Context, masterID, title string) error {
	_, err := a.sessionSvc.Spawn(ctx, masterID, session.SpawnOpts{
		Title:    title,
		Detached: true,
	})
	return err
}

func (a *liveTrackerActions) Stop(ctx context.Context, masterID, workerID string) error {
	// Check manifest before cleanup — ghost entries (no manifest file) need
	// direct removal from the master's Workers list since Deregister
	// can't discover the parent without a manifest.
	_, readErr := a.store.Read(workerID)
	isGhost := errors.Is(readErr, os.ErrNotExist)

	// Kill via run-shell (tmux server context) to avoid socket issues from go run.
	cmd := fmt.Sprintf("tmux kill-session -t %s 2>/dev/null; true", workerID)
	if err := a.tmuxClient.RunShell(ctx, workerID, cmd); err != nil {
		// Fallback: try direct kill if run-shell fails (session might already be dead)
		_, _ = a.sessionSvc.Stop(ctx, workerID)
	} else if !isGhost {
		// Deregister when manifest exists (or has a parse/IO error) —
		// Deregister tolerates missing files and still cleans up runtime dir.
		a.sessionSvc.Deregister(workerID)
	}

	// Ghost fallback: manifest file doesn't exist, so Deregister can't
	// discover the parent. Remove directly from master's Workers list.
	if isGhost {
		_ = a.store.RemoveWorker(masterID, workerID)
	}
	return nil
}

func (a *liveTrackerActions) Delete(ctx context.Context, masterID, workerID string) error {
	// Check manifest before cleanup — ghost entries need direct removal.
	_, readErr := a.store.Read(workerID)

	err := a.sessionSvc.Delete(ctx, workerID)

	// Ghost fallback: only if manifest was already missing.
	if readErr != nil {
		_ = a.store.RemoveWorker(masterID, workerID)
	}
	return err
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

// NewLiveWorkerFetcher creates a WorkerFetcher backed by shared services.
func NewLiveWorkerFetcher(messageSvc *message.Service, tmuxClient *tmux.Client) WorkerFetcher {
	return func(masterID string) []WorkerRow {
		ctx := context.Background()
		workers, err := messageSvc.Workers(ctx, masterID)
		if err != nil {
			return nil
		}

		rows := make([]WorkerRow, 0, len(workers))
		for _, w := range workers {
			row := WorkerRow{
				ID:     w.SessionID,
				Title:  w.Title,
				Status: w.Status,
			}
			if w.Status == "active" {
				row.Snippet = captureWorkerSnippet(ctx, tmuxClient, w.SessionID)
			}
			rows = append(rows, row)
		}
		return rows
	}
}

// captureWorkerSnippet grabs the last few meaningful lines from a worker's Claude pane.
func captureWorkerSnippet(ctx context.Context, tc *tmux.Client, sessionID string) string {
	target, err := tc.ResolveRole(ctx, sessionID, "claude", tmux.WindowWorkspace)
	if err != nil {
		return ""
	}
	captured, err := tc.Capture(ctx, target, 500)
	if err != nil {
		return ""
	}
	return strings.Join(tmux.FilterAgentLines(captured, 4), "\n")
}
