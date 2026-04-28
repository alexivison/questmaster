package tui

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/anthropics/ai-party/tools/party-cli/internal/agent"
	"github.com/anthropics/ai-party/tools/party-cli/internal/claudetodos"
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
	panesByID    map[string][]tmux.Pane
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

func (a *liveTrackerActions) Delete(ctx context.Context, masterID, workerID string) error {
	_, readErr := a.store.Read(workerID)
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
//
// The fetcher owns a per-process Claude-todo cache: on each tick it stats
// the todo file for every active Claude row and re-parses only when mtime
// changes. Invalid JSON keeps the last good state.
func NewLiveSessionFetcher(tmuxClient *tmux.Client, store *state.Store) SessionFetcher {
	todoBaseDir, _ := claudetodos.BaseDir()
	todos := newClaudeTodoCache()

	return func(current SessionInfo) (TrackerSnapshot, error) {
		manifests, err := store.DiscoverSessions()
		if err != nil {
			return TrackerSnapshot{}, fmt.Errorf("discover sessions: %w", err)
		}
		sort.SliceStable(manifests, func(i, j int) bool {
			return stableSessionOrderKey(manifests[i]) > stableSessionOrderKey(manifests[j])
		})

		ctx := context.Background()
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
			if row.Status == "active" {
				if target, err := index.resolveRole(manifest.PartyID, "primary", tmux.WindowWorkspace); err == nil {
					row.Snippet = captureRoleSnippet(ctx, tmuxClient, target, primaryAgent, 4)
				}
			}
			row.TodoOverlay = resolveClaudeTodoOverlay(todos, todoBaseDir, manifest, primaryAgent, row.Status)

			rows = append(rows, row)
		}

		return TrackerSnapshot{
			Sessions:   orderSessionRows(rows),
			Current:    buildCurrentSessionDetail(current, manifestByID),
			ObservedAt: time.Now(),
		}, nil
	}
}

// resolveClaudeTodoOverlay returns the pre-formatted todo overlay line for
// an active Claude row, or "" when the row isn't Claude, isn't active, has
// no resolvable session ID, or has no items on disk.
func resolveClaudeTodoOverlay(
	cache *claudeTodoCache,
	baseDir string,
	manifest state.Manifest,
	primaryAgent agent.Agent,
	status string,
) string {
	if baseDir == "" || cache == nil {
		return ""
	}
	if status != "active" || primaryAgent == nil || primaryAgent.Name() != "claude" {
		return ""
	}
	resumeFilePath := filepath.Join("/tmp", manifest.PartyID, primaryAgent.ResumeFileName())
	claudeSessionID := claudetodos.ResolveSessionID(
		resumeFilePath,
		manifest.ExtraString("claude_session_id"),
		primaryAgentResumeID(manifest),
	)
	if claudeSessionID == "" {
		return ""
	}
	todoState, ok := cache.Fetch(baseDir, claudeSessionID)
	if !ok {
		return ""
	}
	overlay, has := claudetodos.BuildOverlay(todoState)
	if !has {
		return ""
	}
	return overlay.FormatLine()
}

func primaryAgentResumeID(manifest state.Manifest) string {
	for _, spec := range manifest.Agents {
		if spec.Role == string(agent.RolePrimary) {
			return spec.ResumeID
		}
	}
	return ""
}

// claudeTodoCache memoises Claude todo-file reads keyed by session ID. A
// cache miss or an mtime change triggers a re-read; invalid JSON keeps the
// last good state.
type claudeTodoCache struct {
	mu      sync.Mutex
	entries map[string]claudeTodoCacheEntry
}

type claudeTodoCacheEntry struct {
	mtimeUnixNano int64
	state         claudetodos.State
	valid         bool
	populated     bool // distinguishes "never seen" from "seen with mtime 0"
}

func newClaudeTodoCache() *claudeTodoCache {
	return &claudeTodoCache{entries: make(map[string]claudeTodoCacheEntry)}
}

// Fetch returns the todo state for a Claude session ID. The boolean is
// false when no good state is available — either the file is missing or
// we've never successfully parsed it.
func (c *claudeTodoCache) Fetch(baseDir, sessionID string) (claudetodos.State, bool) {
	if sessionID == "" {
		return claudetodos.State{}, false
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	entry := c.entries[sessionID]
	path := claudetodos.Path(baseDir, sessionID)
	fi, err := os.Stat(path)
	if err != nil {
		// File briefly missing (atomic rename-replace): return last good
		// state to avoid overlay flicker. No cache bump so the next tick
		// will stat again.
		if entry.valid {
			return entry.state, true
		}
		return claudetodos.State{}, false
	}

	mtime := fi.ModTime().UnixNano()
	if !entry.populated || entry.mtimeUnixNano != mtime {
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			// Transient read failure (e.g. file vanished between stat
			// and read): return the last good state without bumping the
			// cached mtime so the next tick retries.
			if entry.valid {
				return entry.state, true
			}
			return claudetodos.State{}, false
		}
		if parsed, parseErr := claudetodos.Parse(data); parseErr == nil {
			entry.state = parsed
			entry.valid = true
		}
		// Malformed JSON or partial write: keep last good state; the
		// mtime bump below defers the next re-read until the writer
		// finishes.
		entry.mtimeUnixNano = mtime
		entry.populated = true
		c.entries[sessionID] = entry
	}

	if !entry.valid {
		return claudetodos.State{}, false
	}
	return entry.state, true
}

func buildTrackerSessionIndex(ctx context.Context, tmuxClient *tmux.Client) trackerSessionIndex {
	index := trackerSessionIndex{
		liveSessions: make(map[string]struct{}),
		panesByID:    make(map[string][]tmux.Pane),
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
	if len(index.liveSessions) == 0 {
		return index
	}

	panes, err := tmuxClient.ListAllPanes(ctx)
	if err != nil {
		return index
	}
	for _, pane := range panes {
		index.panesByID[pane.SessionName] = append(index.panesByID[pane.SessionName], pane)
	}
	return index
}

func (i trackerSessionIndex) hasSession(sessionID string) bool {
	_, ok := i.liveSessions[sessionID]
	return ok
}

func (i trackerSessionIndex) resolveRole(sessionID, role string, preferredWindow int) (string, error) {
	return tmux.ResolveRoleFromPanes(sessionID, i.panesByID[sessionID], role, preferredWindow)
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

func captureRoleSnippet(
	ctx context.Context,
	tc *tmux.Client,
	target string,
	resolver agent.Agent,
	maxLines int,
) string {
	if tc == nil || target == "" {
		return ""
	}
	captured, err := tc.Capture(ctx, target, 50)
	if err != nil {
		return ""
	}

	switch {
	case resolver != nil:
		return strings.Join(resolver.FilterPaneLines(captured, maxLines), "\n")
	default:
		return strings.Join(tmux.FilterAgentLines(captured, maxLines), "\n")
	}
}
