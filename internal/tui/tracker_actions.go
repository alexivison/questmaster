package tui

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"time"

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
	Broadcast(ctx context.Context, masterID, message string) error
	Spawn(ctx context.Context, masterID, title string) error
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

type trackerSessionIndex struct {
	liveSessions map[string]struct{}
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

// NewLiveSessionFetcher creates a SessionFetcher backed by shared services.
func NewLiveSessionFetcher(tmuxClient *tmux.Client, store *state.Store) SessionFetcher {
	return func(current SessionInfo) (TrackerSnapshot, error) {
		manifests, err := store.DiscoverSessions()
		if err != nil {
			return TrackerSnapshot{}, fmt.Errorf("discover sessions: %w", err)
		}
		sort.SliceStable(manifests, func(i, j int) bool {
			return stableSessionOrderKey(manifests[i]) > stableSessionOrderKey(manifests[j])
		})

		ctx := context.Background()
		observedAt := time.Now()
		index := buildTrackerSessionIndex(ctx, tmuxClient)
		rows := make([]SessionRow, 0, len(manifests))
		manifestByID := make(map[string]state.Manifest, len(manifests))
		for _, manifest := range manifests {
			manifestByID[manifest.PartyID] = manifest
		}

		for _, manifest := range manifests {
			alive := index.hasSession(manifest.PartyID)

			row := manifestToSessionRow(manifest.PartyID, manifest, alive)
			row.IsCurrent = manifest.PartyID == current.ID

			primaryAgent, companionAgent := resolveSessionAgents(manifest, nil)
			if primaryAgent != nil {
				row.PrimaryAgent = primaryAgent.Name()
			}
			row.HasCompanion = companionAgent != nil

			rows = append(rows, row)
		}

		return TrackerSnapshot{
			Sessions:   orderSessionRows(rows),
			Current:    buildCurrentSessionDetail(current, manifestByID),
			ObservedAt: observedAt,
		}, nil
	}
}

func buildTrackerSessionIndex(ctx context.Context, tmuxClient *tmux.Client) trackerSessionIndex {
	index := trackerSessionIndex{
		liveSessions: make(map[string]struct{}),
	}
	if tmuxClient == nil {
		return index
	}

	liveSessions, err := tmuxClient.ListSessions(ctx)
	if err != nil {
		return index
	}
	for _, sessionID := range liveSessions {
		index.liveSessions[sessionID] = struct{}{}
	}
	return index
}

func (i trackerSessionIndex) hasSession(sessionID string) bool {
	_, ok := i.liveSessions[sessionID]
	return ok
}

func stableSessionOrderKey(manifest state.Manifest) string {
	if manifest.CreatedAt != "" {
		return manifest.CreatedAt + "|" + manifest.PartyID
	}
	return manifest.PartyID
}

func buildCurrentSessionDetail(current SessionInfo, manifestByID map[string]state.Manifest) CurrentSessionDetail {
	if current.ID == "" {
		return CurrentSessionDetail{}
	}

	manifest := current.Manifest
	if manifest.PartyID == "" {
		if m, ok := manifestByID[current.ID]; ok {
			manifest = m
		}
	}

	detail := CurrentSessionDetail{Title: current.Title, SessionType: current.SessionType}
	if manifest.PartyID != "" {
		if detail.Title == "" {
			detail.Title = manifest.Title
		}
		if detail.SessionType == "" {
			detail.SessionType = sessionTypeForManifest(manifest)
		}
	}
	return detail
}

func orderSessionRows(rows []SessionRow) []SessionRow {
	order := make(map[string]int, len(rows))
	byID := make(map[string]SessionRow, len(rows))
	children := make(map[string][]SessionRow)
	topLevel := make([]SessionRow, 0, len(rows))
	orphans := make([]SessionRow, 0, len(rows))

	for i, row := range rows {
		order[row.ID] = i
		byID[row.ID] = row
	}

	for _, row := range rows {
		switch row.SessionType {
		case "master":
			topLevel = append(topLevel, row)
		case "worker":
			if _, ok := byID[row.ParentID]; ok {
				children[row.ParentID] = append(children[row.ParentID], row)
			} else {
				orphans = append(orphans, row)
			}
		default:
			topLevel = append(topLevel, row)
		}
	}

	sortByOrder := func(items []SessionRow) {
		sort.SliceStable(items, func(i, j int) bool {
			return order[items[i].ID] < order[items[j].ID]
		})
	}
	sortByOrder(topLevel)
	sortByOrder(orphans)
	for parentID := range children {
		sortByOrder(children[parentID])
	}

	ordered := make([]SessionRow, 0, len(rows))
	for _, row := range topLevel {
		ordered = append(ordered, row)
		if row.SessionType == "master" {
			ordered = append(ordered, children[row.ID]...)
		}
	}
	ordered = append(ordered, orphans...)
	return ordered
}

func resolveSessionAgents(manifest state.Manifest, registry *agent.Registry) (agent.Agent, agent.Agent) {
	return resolveManifestAgent(manifest, agent.RolePrimary, registry), resolveManifestAgent(manifest, agent.RoleCompanion, registry)
}

func resolveManifestAgent(manifest state.Manifest, role agent.Role, registry *agent.Registry) agent.Agent {
	for _, spec := range manifest.Agents {
		if spec.Role == string(role) {
			return lookupAgent(spec.Name, registry)
		}
	}
	return nil
}

func lookupAgent(name string, registry *agent.Registry) agent.Agent {
	if name == "" {
		return nil
	}
	if registry != nil {
		if resolved, err := registry.Get(name); err == nil {
			return resolved
		}
	}
	if builtinAgentRegistry != nil {
		if resolved, err := builtinAgentRegistry.Get(name); err == nil {
			return resolved
		}
	}
	return nil
}
