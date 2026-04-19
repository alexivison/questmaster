package tui

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/message"
	"github.com/anthropics/ai-party/tools/party-cli/internal/session"
	"github.com/anthropics/ai-party/tools/party-cli/internal/state"
	"github.com/anthropics/ai-party/tools/party-cli/internal/tmux"
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

func (a *liveTrackerActions) Attach(ctx context.Context, currentID, targetID string) error {
	cmd := fmt.Sprintf("tmux switch-client -t %s", targetID)
	return a.tmuxClient.RunShell(ctx, currentID, cmd)
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
	_, readErr := a.store.Read(workerID)
	isGhost := errors.Is(readErr, os.ErrNotExist)

	cmd := fmt.Sprintf("tmux kill-session -t %s 2>/dev/null; true", workerID)
	if err := a.tmuxClient.RunShell(ctx, workerID, cmd); err != nil {
		if _, stopErr := a.sessionSvc.Stop(ctx, workerID); stopErr != nil {
			return fmt.Errorf("stop %s: %w", workerID, stopErr)
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

func (a *liveTrackerActions) Delete(ctx context.Context, masterID, workerID string) error {
	_, readErr := a.store.Read(workerID)
	err := a.sessionSvc.Delete(ctx, workerID)
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
		rows := make([]SessionRow, 0, len(manifests))
		manifestByID := make(map[string]state.Manifest, len(manifests))
		for _, manifest := range manifests {
			manifestByID[manifest.PartyID] = manifest
		}

		for _, manifest := range manifests {
			alive, err := tmuxClient.HasSession(ctx, manifest.PartyID)
			if err != nil {
				alive = false
			}

			row := manifestToSessionRow(manifest.PartyID, manifest, alive)
			row.IsCurrent = manifest.PartyID == current.ID

			primaryAgent, companionAgent := resolveSessionAgents(manifest, nil)
			if primaryAgent != nil {
				row.PrimaryAgent = primaryAgent.Name()
			}
			row.HasCompanion = companionAgent != nil
			if row.Status == "active" {
				row.Snippet = captureRoleSnippet(ctx, tmuxClient, manifest.PartyID, "primary", tmux.WindowWorkspace, primaryAgent, 4)
				row.PrimaryActive = agentActive(primaryAgent, manifest)
				if companionAgent != nil {
					row.CompanionActive = agentActive(companionAgent, manifest)
				}
			}

			rows = append(rows, row)
		}

		return TrackerSnapshot{
			Sessions: orderSessionRows(rows),
			Current:  buildCurrentSessionDetail(ctx, current, manifestByID, tmuxClient),
		}, nil
	}
}

func stableSessionOrderKey(manifest state.Manifest) string {
	if manifest.CreatedAt != "" {
		return manifest.CreatedAt + "|" + manifest.PartyID
	}
	return manifest.PartyID
}

func buildCurrentSessionDetail(
	ctx context.Context,
	current SessionInfo,
	manifestByID map[string]state.Manifest,
	tmuxClient *tmux.Client,
) CurrentSessionDetail {
	if current.ID == "" {
		return CurrentSessionDetail{}
	}

	manifest := current.Manifest
	if manifest.PartyID == "" {
		if m, ok := manifestByID[current.ID]; ok {
			manifest = m
		}
	}

	detail := CurrentSessionDetail{
		ID:          current.ID,
		Title:       current.Title,
		SessionType: current.SessionType,
		Cwd:         current.Cwd,
	}
	if manifest.PartyID != "" {
		if detail.Title == "" {
			detail.Title = manifest.Title
		}
		if detail.SessionType == "" {
			detail.SessionType = sessionTypeForManifest(manifest)
		}
		if detail.Cwd == "" {
			detail.Cwd = manifest.Cwd
		}
		detail.WorkerCount = len(manifest.Workers)
	}

	primaryAgent, companionAgent := resolveSessionAgents(manifest, current.Registry)
	if primaryAgent != nil {
		detail.PrimaryAgent = primaryAgent.Name()
	}
	detail.Evidence = ReadEvidenceSummary(evidenceLookupID(current.ID, manifest, primaryAgent), 6)
	if companionAgent != nil {
		detail.CompanionName = companionAgent.Name()
	}
	return detail
}

func orderSessionRows(rows []SessionRow) []SessionRow {
	order := make(map[string]int, len(rows))
	byID := make(map[string]SessionRow, len(rows))
	children := make(map[string][]SessionRow)
	masters := make([]SessionRow, 0, len(rows))
	standalones := make([]SessionRow, 0, len(rows))
	orphans := make([]SessionRow, 0, len(rows))

	for i, row := range rows {
		order[row.ID] = i
		byID[row.ID] = row
	}

	for _, row := range rows {
		switch row.SessionType {
		case "master":
			masters = append(masters, row)
		case "worker":
			if _, ok := byID[row.ParentID]; ok {
				children[row.ParentID] = append(children[row.ParentID], row)
			} else {
				orphans = append(orphans, row)
			}
		default:
			standalones = append(standalones, row)
		}
	}

	sortByOrder := func(items []SessionRow) {
		sort.SliceStable(items, func(i, j int) bool {
			return order[items[i].ID] < order[items[j].ID]
		})
	}
	sortByOrder(masters)
	sortByOrder(standalones)
	sortByOrder(orphans)
	for parentID := range children {
		sortByOrder(children[parentID])
	}

	ordered := make([]SessionRow, 0, len(rows))
	for _, master := range masters {
		ordered = append(ordered, master)
		ordered = append(ordered, children[master.ID]...)
	}
	ordered = append(ordered, standalones...)
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

func evidenceLookupID(sessionID string, manifest state.Manifest, primaryAgent agent.Agent) string {
	if primaryAgent == nil || primaryAgent.Name() != "claude" {
		return sessionID
	}

	for _, spec := range manifest.Agents {
		if spec.Role == string(agent.RolePrimary) && spec.ResumeID != "" {
			return spec.ResumeID
		}
	}
	return sessionID
}

// agentActive queries the agent for its own activity signal. The agent
// owns the heuristic (typically a live-transcript mtime check) so the
// TUI is not coupled to any on-disk layout.
func agentActive(a agent.Agent, manifest state.Manifest) bool {
	if a == nil {
		return false
	}
	resumeID := resumeIDFor(a, manifest)
	if resumeID == "" {
		return false
	}
	active, err := a.IsActive(manifest.Cwd, resumeID)
	if err != nil {
		return false
	}
	return active
}

// resumeIDFor pulls the agent's resume ID from the Agents array.
func resumeIDFor(a agent.Agent, m state.Manifest) string {
	name := a.Name()
	for _, spec := range m.Agents {
		if spec.Name == name && spec.ResumeID != "" {
			return spec.ResumeID
		}
	}
	return ""
}

func captureRoleSnippet(
	ctx context.Context,
	tc *tmux.Client,
	sessionID, role string,
	preferredWindow int,
	resolver agent.Agent,
	maxLines int,
) string {
	if tc == nil || sessionID == "" {
		return ""
	}

	target, err := tc.ResolveRole(ctx, sessionID, role, preferredWindow)
	if err != nil {
		return ""
	}
	captured, err := tc.Capture(ctx, target, 500)
	if err != nil {
		return ""
	}

	switch {
	case resolver != nil:
		return strings.Join(resolver.FilterPaneLines(captured, maxLines), "\n")
	case role == "companion":
		return strings.Join(tmux.FilterWizardLines(captured, maxLines), "\n")
	default:
		return strings.Join(tmux.FilterAgentLines(captured, maxLines), "\n")
	}
}
