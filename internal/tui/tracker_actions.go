package tui

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/message"
	"github.com/alexivison/questmaster/internal/quests/quest"
	qruntime "github.com/alexivison/questmaster/internal/quests/runtime"
	"github.com/alexivison/questmaster/internal/repo"
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
	return a.store.Update(sessionID, func(m *state.Manifest) {
		if sessionTypeForManifest(*m) == "worker" {
			return
		}
		color = strings.TrimSpace(color)
		if color == "" {
			if m.Display != nil {
				m.Display.Color = ""
				m.Display.ColorChangedAt = ""
				if m.Display.IsZero() {
					m.Display = nil
				}
			}
			return
		}
		if m.Display == nil {
			m.Display = state.NewDisplayMetadata(color)
		} else {
			m.Display.Color = state.NormalizeDisplayColor(color)
		}
		// Stamp the change so last-write-wins can rank it against a repo color.
		m.Display.ColorChangedAt = state.NowColorStamp()
	})
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

// NewLiveSessionFetcher creates a SessionFetcher backed by shared services.
// The repo-resolution cache and repo-color store are created once and captured
// by the returned closure so they persist across refresh ticks (a session's
// cwd does not change repos within a run, and repo colors only change on a C).
func NewLiveSessionFetcher(tmuxClient *tmux.Client, store *state.Store) SessionFetcher {
	repoCache := repo.NewCache()
	repoColors := state.NewRepoColorStore(store.Root())
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
		// Graceful degradation: a missing/unreadable store leaves a nil map,
		// which reads as "no repo colors" rather than failing the refresh.
		repoColorMap, _ := repoColors.Load()
		rows := make([]SessionRow, 0, len(manifests))
		manifestByID := make(map[string]state.Manifest, len(manifests))
		for _, manifest := range manifests {
			manifestByID[manifest.SessionID] = manifest
		}

		for _, manifest := range manifests {
			alive := index.hasSession(manifest.SessionID)

			row := manifestToSessionRow(manifest.SessionID, manifest, alive)
			row.IsCurrent = manifest.SessionID == current.ID

			primaryAgent := resolveSessionAgent(manifest, nil)
			if primaryAgent != nil {
				row.PrimaryAgent = primaryAgent.Name()
			}

			// Any explicitly attached session carries its id + goal for the
			// tracker quest line.
			if ss, _ := state.LoadSessionState(manifest.SessionID); ss != nil && ss.QuestID != "" {
				row.QuestID = ss.QuestID
				row.QuestLoop = qruntime.LoopRuntime(manifest.SessionID, ss.QuestLoop)
				if q, err := quest.DefaultStore().Load(ss.QuestID); err == nil {
					row.QuestTitle = q.Title
				}
			}

			resolveRepoColor(&row, manifest, repoCache, repoColorMap)
			rows = append(rows, row)
		}
		inheritWorkerDisplayColors(rows)

		return TrackerSnapshot{
			Sessions:   groupRowsByRepo(orderSessionRows(rows)),
			Current:    buildCurrentSessionDetail(current, manifestByID),
			ObservedAt: observedAt,
		}, nil
	}
}

// resolveRepoColor resolves a row's parent repo and folds the repo color into
// its effective (last-write-wins) DisplayColor. Worker rows are left for
// inheritWorkerDisplayColors, which copies their master's effective color.
func resolveRepoColor(row *SessionRow, manifest state.Manifest, cache *repo.Cache, repoColorMap map[string]state.RepoColor) {
	r, ok := cache.Resolve(manifest.Cwd)
	if !ok {
		return // not in a git repo → ungrouped, no repo color
	}
	// Every row (workers included) gets its own resolved repo. For a worker
	// with a live master, groupRowsByRepo later re-propagates the master's
	// repo so the tree groups as one; this own-cwd value is what an orphan
	// worker (master deleted) keeps, so it still lands in its repo's section.
	row.RepoIdentity = r.Identity
	row.RepoName = r.Name

	rc, hasRepoColor := repoColorMap[r.Identity]
	if hasRepoColor {
		row.RepoColor = rc.Color
	}
	// Workers take their master's effective color via inheritWorkerDisplayColors;
	// only non-workers resolve last-write-wins against the repo color here.
	if row.SessionType == "worker" {
		return
	}

	var ownAt time.Time
	if manifest.Display != nil {
		ownAt = state.ParseColorStamp(manifest.Display.ColorChangedAt)
	}
	row.DisplayColor = state.EffectiveColor(row.DisplayColor, ownAt, rc.Color, state.ParseColorStamp(rc.UpdatedAt))
}

func inheritWorkerDisplayColors(rows []SessionRow) {
	parentColors := make(map[string]string, len(rows))
	for _, row := range rows {
		if row.SessionType != "worker" && row.DisplayColor != "" {
			parentColors[row.ID] = row.DisplayColor
		}
	}
	for i := range rows {
		if rows[i].SessionType != "worker" {
			continue
		}
		rows[i].DisplayColor = parentColors[rows[i].ParentID]
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
		return manifest.CreatedAt + "|" + manifest.SessionID
	}
	return manifest.SessionID
}

func buildCurrentSessionDetail(current SessionInfo, manifestByID map[string]state.Manifest) CurrentSessionDetail {
	if current.ID == "" {
		return CurrentSessionDetail{}
	}

	manifest := current.Manifest
	if manifest.SessionID == "" {
		if m, ok := manifestByID[current.ID]; ok {
			manifest = m
		}
	}

	detail := CurrentSessionDetail{Title: current.Title, SessionType: current.SessionType}
	if manifest.SessionID != "" {
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

// groupRowsByRepo regroups already-tree-ordered rows into repo sections:
// alphabetical by repo name with the ungrouped section (cwd not in a repo)
// last — the same rule the quest board uses for project sections — while
// preserving each section's existing within-section order. A master and its
// nested workers move together as one unit, so a tree is never split across
// sections; the unit's section is the top-level row's repo, and that repo is
// propagated onto its workers so they group, render, and recolor (C) under
// their master's repo.
func groupRowsByRepo(rows []SessionRow) []SessionRow {
	type unit struct {
		identity string
		name     string
		rows     []SessionRow
	}

	var units []unit
	for i := 0; i < len(rows); {
		head := rows[i]
		group := []SessionRow{head}
		j := i + 1
		if head.SessionType == "master" {
			for j < len(rows) && rows[j].SessionType == "worker" && rows[j].ParentID == head.ID {
				worker := rows[j]
				worker.RepoIdentity = head.RepoIdentity
				worker.RepoName = head.RepoName
				worker.RepoColor = head.RepoColor
				group = append(group, worker)
				j++
			}
		}
		units = append(units, unit{identity: head.RepoIdentity, name: head.RepoName, rows: group})
		i = j
	}

	sort.SliceStable(units, func(a, b int) bool {
		return lessRepoSection(units[a].identity, units[a].name, units[b].identity, units[b].name)
	})

	ordered := make([]SessionRow, 0, len(rows))
	for _, u := range units {
		ordered = append(ordered, u.rows...)
	}
	return ordered
}

// lessRepoSection orders repo sections alphabetically by name with the
// ungrouped section (empty identity) always last; equal names break ties by
// identity so same-named clones stay deterministically grouped.
func lessRepoSection(aID, aName, bID, bName string) bool {
	aUngrouped := aID == ""
	bUngrouped := bID == ""
	switch {
	case aUngrouped && bUngrouped:
		return false
	case aUngrouped:
		return false
	case bUngrouped:
		return true
	}
	if aName != bName {
		return aName < bName
	}
	return aID < bID
}

func resolveSessionAgent(manifest state.Manifest, registry *agent.Registry) agent.Agent {
	return resolveManifestAgent(manifest, agent.RolePrimary, registry)
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
