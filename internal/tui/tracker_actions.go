package tui

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"

	"github.com/anthropics/ai-config/tools/party-cli/internal/message"
	"github.com/anthropics/ai-config/tools/party-cli/internal/session"
	"github.com/anthropics/ai-config/tools/party-cli/internal/state"
	"github.com/anthropics/ai-config/tools/party-cli/internal/tmux"
)

// TrackerActions defines the operations the tracker can perform.
type TrackerActions interface {
	Attach(ctx context.Context, workerID string) error
	Relay(ctx context.Context, workerID, message string) error
	Broadcast(ctx context.Context, masterID, message string) error
	Spawn(ctx context.Context, masterID, title string) error
	Stop(ctx context.Context, workerID string) error
	Delete(ctx context.Context, workerID string) error
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

func (a *liveTrackerActions) Attach(ctx context.Context, workerID string) error {
	return a.tmuxClient.SwitchClient(ctx, workerID)
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

func (a *liveTrackerActions) Stop(ctx context.Context, workerID string) error {
	_, err := a.sessionSvc.Stop(ctx, workerID)
	return err
}

func (a *liveTrackerActions) Delete(ctx context.Context, workerID string) error {
	return a.sessionSvc.Delete(ctx, workerID)
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
	return filterSnippetLines(captured, 4)
}

// filterSnippetLines extracts the last N meaningful lines (agent actions/prompts).
func filterSnippetLines(captured string, n int) string {
	lines := strings.Split(captured, "\n")
	var meaningful []string
	for _, l := range lines {
		trimmed := strings.TrimSpace(l)
		if strings.HasPrefix(trimmed, "\u23fa") || strings.HasPrefix(trimmed, "\u276f") {
			if trimmed != "\u23fa" && trimmed != "\u276f" {
				meaningful = append(meaningful, trimmed)
			}
		}
	}
	if len(meaningful) == 0 {
		return ""
	}
	start := len(meaningful) - n
	if start < 0 {
		start = 0
	}
	return strings.Join(meaningful[start:], "\n")
}
