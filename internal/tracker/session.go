package tracker

import (
	"context"
	"fmt"
	"sort"
	"time"

	"github.com/alexivison/questmaster/internal/agent"
	"github.com/alexivison/questmaster/internal/quests/quest"
	qruntime "github.com/alexivison/questmaster/internal/quests/runtime"
	"github.com/alexivison/questmaster/internal/repo"
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

// SessionInfo holds resolved session metadata.
type SessionInfo struct {
	ID          string
	Title       string
	Cwd         string
	SessionType string
	Manifest    state.Manifest
	Registry    *agent.Registry
}

// SessionRow is the display-ready session data for the tracker.
//
// State / LastKind come from the per-session state.json that hooks write.
type SessionRow struct {
	ID           string
	Title        string
	Cwd          string
	PrimaryAgent string
	Status       string // "active" or "stopped"
	SessionType  string // "master", "worker", or "standalone"
	ParentID     string
	WorkerCount  int
	DisplayColor string // effective (last-write-wins) gutter color
	Snippet      string

	// Repo grouping. RepoIdentity is the canonical parent-repo key (shared by
	// all worktrees of a repo); "" means the cwd is not in a git repo and the
	// row lands in the trailing ungrouped section. RepoColor is the repo's own
	// persisted color (drives the section header), independent of any session
	// override folded into DisplayColor.
	RepoIdentity string
	RepoName     string
	RepoColor    string
	State        string // working|blocked|done|idle|starting|stopped|unknown
	LastKind     string // last hook event kind (drives streaming-prose suffix)
	WorkingSince time.Time
	IsCurrent    bool

	// QuestID/QuestTitle carry the session's explicit quest attachment.
	// Derived from the session scan, never stored on the quest.
	QuestID    string
	QuestTitle string
	QuestLoop  *quest.LoopRuntime
}

// TrackerSnapshot is the full rendered data set for one refresh tick.
type TrackerSnapshot struct {
	Sessions   []SessionRow
	Current    CurrentSessionDetail
	ObservedAt time.Time
}

// CurrentSessionDetail carries the current session metadata needed by the
// tracker header.
type CurrentSessionDetail struct {
	Title       string
	SessionType string
}

// SessionFetcher loads all session data for the tracker.
type SessionFetcher func(current SessionInfo) (TrackerSnapshot, error)

type sessionIndex struct {
	liveSessions map[string]struct{}
}

// NewLiveSessionFetcher creates a SessionFetcher backed by shared services.
// The repo-resolution cache and repo-color store are created once and captured
// by the returned closure so they persist across refresh ticks (a session's
// cwd does not change repos within a run, and repo colors only change on a C).
func NewLiveSessionFetcher(tmuxClient *tmux.Client, store *state.Store) SessionFetcher {
	repoCache := repo.NewCache()
	repoColors := state.NewRepoColorStore(store.Root())
	// Session state lives under StateRoot() (env-resolved), which is not always
	// the manifest store's root - resolve it once here instead of re-reading the
	// environment for every session on every tick.
	stateRoot := state.StateRoot()
	questStore := quest.DefaultStore()
	return func(current SessionInfo) (TrackerSnapshot, error) {
		manifests, err := store.DiscoverSessions()
		if err != nil {
			return TrackerSnapshot{}, fmt.Errorf("discover sessions: %w", err)
		}
		sort.SliceStable(manifests, func(i, j int) bool {
			return StableSessionOrderKey(manifests[i]) > StableSessionOrderKey(manifests[j])
		})

		ctx := context.Background()
		observedAt := time.Now()
		index := buildSessionIndex(ctx, tmuxClient)
		// Graceful degradation: a missing/unreadable store leaves a nil map,
		// which reads as "no repo colors" rather than failing the refresh.
		repoColorMap, _ := repoColors.Load()
		rows := make([]SessionRow, 0, len(manifests))
		manifestByID := make(map[string]state.Manifest, len(manifests))
		for _, manifest := range manifests {
			manifestByID[manifest.SessionID] = manifest
		}

		// questTitles dedups quest loads within this tick: several sessions can
		// share one quest, and each load reads + regex-parses the quest HTML. ""
		// memoizes a failed/empty load so it is attempted at most once per quest.
		questTitles := make(map[string]string)

		for _, manifest := range manifests {
			alive := index.hasSession(manifest.SessionID)

			row := ManifestToSessionRow(manifest.SessionID, manifest, alive)
			row.IsCurrent = manifest.SessionID == current.ID

			primaryAgent := resolveSessionAgent(manifest, nil)
			if primaryAgent != nil {
				row.PrimaryAgent = primaryAgent.Name()
			}

			// Any explicitly attached session carries its id + goal for the
			// tracker quest line. Resolve the state root once (above) rather than
			// re-reading $HOME/env per session.
			if ss, _ := state.LoadSessionStateAt(stateRoot, manifest.SessionID); ss != nil && ss.QuestID != "" {
				row.QuestID = ss.QuestID
				row.QuestLoop = qruntime.LoopRuntime(manifest.SessionID, ss.QuestLoop)
				title, ok := questTitles[ss.QuestID]
				if !ok {
					if q, err := questStore.Load(ss.QuestID); err == nil {
						title = q.Title
					}
					questTitles[ss.QuestID] = title
				}
				row.QuestTitle = title
			}

			resolveRepoColor(&row, manifest, repoCache, repoColorMap)
			rows = append(rows, row)
		}
		inheritWorkerDisplayColors(rows)

		return TrackerSnapshot{
			Sessions:   GroupRowsByRepo(OrderSessionRows(rows)),
			Current:    buildCurrentSessionDetail(current, manifestByID),
			ObservedAt: observedAt,
		}, nil
	}
}

// ManifestToSessionRow converts manifest data plus liveness into a tracker row.
func ManifestToSessionRow(id string, m state.Manifest, alive bool) SessionRow {
	sessionType := SessionTypeForManifest(m)
	status := "stopped"
	if alive {
		status = "active"
	}

	return SessionRow{
		ID:           id,
		Title:        m.Title,
		Cwd:          m.Cwd,
		Status:       status,
		SessionType:  sessionType,
		ParentID:     m.ExtraString("parent_session"),
		WorkerCount:  len(m.Workers),
		DisplayColor: m.DisplayColor(),
	}
}

// SessionTypeForManifest normalizes persisted manifest metadata into the
// tracker session-type vocabulary.
func SessionTypeForManifest(m state.Manifest) string {
	if m.SessionType == "master" {
		return "master"
	}
	if m.ExtraString("parent_session") != "" {
		return "worker"
	}
	return "standalone"
}

// StableSessionOrderKey returns the newest-first sort key used by tracker rows.
func StableSessionOrderKey(manifest state.Manifest) string {
	if manifest.CreatedAt != "" {
		return manifest.CreatedAt + "|" + manifest.SessionID
	}
	return manifest.SessionID
}

// OrderSessionRows nests workers after their masters while preserving the
// newest-first order inside each level.
func OrderSessionRows(rows []SessionRow) []SessionRow {
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

// GroupRowsByRepo regroups already-tree-ordered rows into repo sections:
// alphabetical by repo name with the ungrouped section (cwd not in a repo)
// last - the same rule the quest board uses for project sections - while
// preserving each section's existing within-section order. A master and its
// nested workers move together as one unit, so a tree is never split across
// sections; the unit's section is the top-level row's repo, and that repo is
// propagated onto its workers so they group and recolor under their master.
func GroupRowsByRepo(rows []SessionRow) []SessionRow {
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

// resolveRepoColor resolves a row's parent repo and folds the repo color into
// its effective (last-write-wins) DisplayColor. Worker rows are left for
// inheritWorkerDisplayColors, which copies their master's effective color.
func resolveRepoColor(row *SessionRow, manifest state.Manifest, cache *repo.Cache, repoColorMap map[string]state.RepoColor) {
	r, ok := cache.Resolve(manifest.Cwd)
	if !ok {
		return
	}
	// Every row (workers included) gets its own resolved repo. For a worker
	// with a live master, GroupRowsByRepo later re-propagates the master's
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

func buildSessionIndex(ctx context.Context, tmuxClient *tmux.Client) sessionIndex {
	index := sessionIndex{
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

func (i sessionIndex) hasSession(sessionID string) bool {
	_, ok := i.liveSessions[sessionID]
	return ok
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
			detail.SessionType = SessionTypeForManifest(manifest)
		}
	}
	return detail
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
