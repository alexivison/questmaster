//go:build linux || darwin

// Package serve exposes read-only questmaster runtime snapshots over a local
// transport. It is a presentation layer over the existing quest, runtime, and
// tracker readers; it never owns orchestration state.
package serve

import (
	"context"
	"os"
	"path/filepath"
	"time"

	"github.com/alexivison/questmaster/internal/quests/gate"
	"github.com/alexivison/questmaster/internal/quests/quest"
	qruntime "github.com/alexivison/questmaster/internal/quests/runtime"
	"github.com/alexivison/questmaster/internal/sessionactivity"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tui"
	"github.com/alexivison/questmaster/internal/workspace"
)

// Snapshotter builds the read-only data surfaces served to clients.
type Snapshotter struct {
	store   *state.Store
	fetcher tui.SessionFetcher
	now     func() time.Time
}

// NewSnapshotter creates a snapshot reader from existing qm services.
func NewSnapshotter(store *state.Store, tmuxClient *tmux.Client, now func() time.Time) *Snapshotter {
	if store == nil {
		store = state.OpenStore(state.StateRoot())
	}
	if tmuxClient == nil {
		tmuxClient = tmux.NewExecClient()
	}
	if now == nil {
		now = time.Now
	}
	return &Snapshotter{
		store:   store,
		fetcher: tui.NewLiveSessionFetcher(tmuxClient, store),
		now:     now,
	}
}

// StateRoot returns the durable session-state root read by serve.
func (s *Snapshotter) StateRoot() string {
	if s == nil || s.store == nil {
		return state.StateRoot()
	}
	return s.store.Root()
}

// QuestDir returns the durable quest JSON/HTML store read by serve.
func (s *Snapshotter) QuestDir() string {
	return quest.DefaultStore().Dir()
}

// RuntimeDir returns the durable auto-gate sidecar directory read by serve.
func (s *Snapshotter) RuntimeDir() string {
	if sidecar := runtimeSidecar(); sidecar != nil {
		return sidecar.Dir()
	}
	return ""
}

// SessionQuestID returns the quest currently stamped on a session, if any.
func (s *Snapshotter) SessionQuestID(sessionID string) string {
	ss, err := state.LoadSessionStateAt(s.StateRoot(), sessionID)
	if err != nil || ss == nil {
		return ""
	}
	return ss.QuestID
}

// SessionQuestIndex returns the current session->quest attachment map. It is
// used only to classify future file events, especially deletes and detaches.
func (s *Snapshotter) SessionQuestIndex() map[string]string {
	root := s.StateRoot()
	if root == "" {
		return nil
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		return nil
	}
	out := make(map[string]string)
	for _, entry := range entries {
		if !entry.IsDir() || !state.IsValidSessionID(entry.Name()) {
			continue
		}
		if questID := s.SessionQuestID(entry.Name()); questID != "" {
			out[entry.Name()] = questID
		}
	}
	return out
}

// BoardSnapshot is the native quest board's read model.
type BoardSnapshot struct {
	ObservedAt time.Time    `json:"observed_at"`
	Groups     []BoardGroup `json:"groups"`
}

// BoardGroup is one repo/project section on the board.
type BoardGroup struct {
	Repo   string       `json:"repo"`
	Quests []BoardQuest `json:"quests"`
}

// BoardQuest pairs the authored quest JSON with its derived runtime.
type BoardQuest struct {
	Quest   quest.Quest          `json:"quest"`
	Runtime QuestRuntimeSnapshot `json:"runtime"`
}

// QuestSnapshot is the native quest viewer's read model.
type QuestSnapshot struct {
	Quest      *quest.Quest         `json:"quest"`
	Runtime    QuestRuntimeSnapshot `json:"runtime"`
	ObservedAt time.Time            `json:"observed_at"`
}

// QuestRuntimeSnapshot is the serve-facing runtime shape. The core quest
// package still exposes the legacy Adventurers field; serve keeps that field
// for compatibility and also exposes the same rows under the canonical
// session_details name.
type QuestRuntimeSnapshot struct {
	Sessions       []string               `json:"sessions"`
	SessionDetails []QuestSessionSnapshot `json:"session_details,omitempty"`
	Adventurers    []QuestSessionSnapshot `json:"adventurers,omitempty"`
	Agent          string                 `json:"agent"`
	Gates          map[string]string      `json:"gates,omitempty"`
	GatesAt        map[string]time.Time   `json:"gates_at,omitempty"`
	ObservedAt     time.Time              `json:"observed_at"`
	Loop           *quest.LoopRuntime     `json:"loop,omitempty"`
}

// QuestSessionSnapshot is one attached session's live quest activity.
type QuestSessionSnapshot struct {
	ID    string             `json:"id"`
	Agent string             `json:"agent,omitempty"`
	State string             `json:"state,omitempty"`
	Since time.Time          `json:"since,omitempty"`
	Loop  *quest.LoopRuntime `json:"loop,omitempty"`
}

// TrackerSnapshot is the native tracker's read model.
type TrackerSnapshot struct {
	ObservedAt time.Time         `json:"observed_at"`
	Current    *CurrentSession   `json:"current,omitempty"`
	Sessions   []SessionSnapshot `json:"sessions"`
}

// ItemsSnapshot is the read-only workspace item list served from the qm state
// root with loose/attachment counts derived from quest JSON.
type ItemsSnapshot struct {
	ObservedAt time.Time              `json:"observed_at"`
	Items      []workspace.ListedItem `json:"items"`
}

// CurrentSession identifies the session the current process is attached to,
// when QUESTMASTER_SESSION gives serve that context.
type CurrentSession struct {
	ID          string `json:"id"`
	Title       string `json:"title,omitempty"`
	SessionType string `json:"session_type,omitempty"`
}

// SessionSnapshot is one tracker row with live activity already applied.
type SessionSnapshot struct {
	ID             string             `json:"id"`
	Title          string             `json:"title,omitempty"`
	Status         string             `json:"status"`
	State          string             `json:"state,omitempty"`
	ElapsedMS      int64              `json:"elapsed_ms"`
	ElapsedSince   *time.Time         `json:"elapsed_since,omitempty"`
	LatestActivity string             `json:"latest_activity,omitempty"`
	LastKind       string             `json:"last_kind,omitempty"`
	WorktreePath   string             `json:"worktree_path,omitempty"`
	PrimaryAgent   string             `json:"primary_agent,omitempty"`
	SessionType    string             `json:"session_type,omitempty"`
	ParentID       string             `json:"parent_id,omitempty"`
	WorkerCount    int                `json:"worker_count"`
	IsCurrent      bool               `json:"is_current"`
	QuestID        string             `json:"quest_id,omitempty"`
	QuestTitle     string             `json:"quest_title,omitempty"`
	QuestLoop      *quest.LoopRuntime `json:"quest_loop,omitempty"`
	Repo           RepoSnapshot       `json:"repo,omitempty"`
	DisplayColor   string             `json:"display_color,omitempty"`
}

// RepoSnapshot carries tracker repo grouping metadata.
type RepoSnapshot struct {
	Identity string `json:"identity,omitempty"`
	Name     string `json:"name,omitempty"`
	Color    string `json:"color,omitempty"`
}

// Board returns quests grouped in the same project order as the TUI board,
// with runtime injected from the shared runtime derivation.
func (s *Snapshotter) Board(context.Context) (BoardSnapshot, error) {
	observedAt := s.now().UTC()
	qs, err := quest.DefaultStore().List()
	if err != nil {
		return BoardSnapshot{}, err
	}
	ids := make([]string, len(qs))
	for i, q := range qs {
		ids[i] = q.ID
	}
	runtimes := qruntime.Snapshot(runtimeSidecar(), ids, observedAt)

	groups := quest.GroupByProject(qs)
	out := BoardSnapshot{
		ObservedAt: observedAt,
		Groups:     make([]BoardGroup, len(groups)),
	}
	for i, group := range groups {
		out.Groups[i] = BoardGroup{
			Repo:   group.Project,
			Quests: make([]BoardQuest, len(group.Quests)),
		}
		for j, q := range group.Quests {
			out.Groups[i].Quests[j] = BoardQuest{Quest: q, Runtime: runtimeSnapshot(runtimes[q.ID])}
		}
	}
	return out, nil
}

// Quest returns one authored quest JSON document plus its live runtime.
func (s *Snapshotter) Quest(_ context.Context, id string) (QuestSnapshot, error) {
	q, err := quest.DefaultStore().Load(id)
	if err != nil {
		return QuestSnapshot{}, err
	}
	rt := qruntime.Snapshot(runtimeSidecar(), []string{id}, s.now().UTC())[id]
	return QuestSnapshot{Quest: q, Runtime: runtimeSnapshot(rt), ObservedAt: rt.ObservedAt}, nil
}

func (s *Snapshotter) Items(context.Context) (ItemsSnapshot, error) {
	items, err := workspace.OpenStore(s.StateRoot()).List()
	if err != nil {
		return ItemsSnapshot{}, err
	}
	quests, err := quest.DefaultStore().List()
	if err != nil {
		return ItemsSnapshot{}, err
	}
	if items == nil {
		items = []workspace.Item{}
	}
	return ItemsSnapshot{
		ObservedAt: s.now().UTC(),
		Items:      workspace.WithAttachmentUsage(items, quests),
	}, nil
}

func runtimeSnapshot(rt quest.Runtime) QuestRuntimeSnapshot {
	details := make([]QuestSessionSnapshot, 0, len(rt.Adventurers)+len(rt.Sessions))
	seen := make(map[string]struct{}, len(rt.Adventurers)+len(rt.Sessions))
	for _, adventurer := range rt.Adventurers {
		if adventurer.ID == "" {
			continue
		}
		seen[adventurer.ID] = struct{}{}
		details = append(details, QuestSessionSnapshot{
			ID:    adventurer.ID,
			Agent: adventurer.Agent,
			State: adventurer.State,
			Since: adventurer.Since,
			Loop:  adventurer.Loop,
		})
	}
	for _, id := range rt.Sessions {
		if id == "" {
			continue
		}
		if _, ok := seen[id]; ok {
			continue
		}
		details = append(details, QuestSessionSnapshot{ID: id})
	}
	sessions := make([]string, 0, len(details))
	for _, detail := range details {
		sessions = append(sessions, detail.ID)
	}
	return QuestRuntimeSnapshot{
		Sessions:       sessions,
		SessionDetails: details,
		Adventurers:    details,
		Agent:          rt.Agent,
		Gates:          rt.Gates,
		GatesAt:        rt.GatesAt,
		ObservedAt:     rt.ObservedAt,
		Loop:           rt.Loop,
	}
}

// Tracker returns the tracker row model with hook-driven activity applied.
func (s *Snapshotter) Tracker(context.Context) (TrackerSnapshot, error) {
	current := s.currentSession()
	snap, err := s.fetcher(current)
	if err != nil {
		return TrackerSnapshot{}, err
	}
	observedAt := snap.ObservedAt.UTC()
	if observedAt.IsZero() {
		observedAt = s.now().UTC()
	}
	return TrackerSnapshot{
		ObservedAt: observedAt,
		Current:    currentSessionSnapshot(current),
		Sessions:   sessionSnapshots(snap.Sessions, observedAt),
	}, nil
}

func (s *Snapshotter) currentSession() tui.SessionInfo {
	id := state.SessionIDFromEnv()
	if id == "" || !state.IsValidSessionID(id) {
		return tui.SessionInfo{}
	}
	m, err := s.store.Read(id)
	if err != nil {
		return tui.SessionInfo{ID: id}
	}
	return tui.SessionInfo{
		ID:          id,
		Title:       m.Title,
		Cwd:         m.Cwd,
		SessionType: manifestSessionType(m),
		Manifest:    m,
	}
}

func currentSessionSnapshot(current tui.SessionInfo) *CurrentSession {
	if current.ID == "" {
		return nil
	}
	return &CurrentSession{
		ID:          current.ID,
		Title:       current.Title,
		SessionType: current.SessionType,
	}
}

func sessionSnapshots(rows []tui.SessionRow, observedAt time.Time) []SessionSnapshot {
	observations := make([]sessionactivity.Observation, 0, len(rows))
	keys := make([]string, len(rows))
	for i := range rows {
		key := sessionactivity.PrimaryKey(rows[i].ID)
		keys[i] = key
		observations = append(observations, sessionactivity.Observation{
			Key:       key,
			SessionID: rows[i].ID,
			Enabled:   rows[i].Status == "active",
		})
	}
	activity := sessionactivity.Evaluate(observations)

	out := make([]SessionSnapshot, len(rows))
	for i, row := range rows {
		result := activity[keys[i]]
		stateName := row.State
		if stateName == "" {
			stateName = result.State
		}
		lastKind := row.LastKind
		if lastKind == "" {
			lastKind = result.LastKind
		}
		snippet := row.Snippet
		if result.Activity != "" {
			snippet = result.Activity
		}
		elapsedSince := result.WorkingSince
		if elapsedSince.IsZero() {
			elapsedSince = result.LastEvent
		}

		out[i] = SessionSnapshot{
			ID:             row.ID,
			Title:          row.Title,
			Status:         row.Status,
			State:          stateName,
			ElapsedMS:      elapsedMS(observedAt, elapsedSince),
			ElapsedSince:   timePtr(elapsedSince),
			LatestActivity: snippet,
			LastKind:       lastKind,
			WorktreePath:   row.Cwd,
			PrimaryAgent:   row.PrimaryAgent,
			SessionType:    row.SessionType,
			ParentID:       row.ParentID,
			WorkerCount:    row.WorkerCount,
			IsCurrent:      row.IsCurrent,
			QuestID:        row.QuestID,
			QuestTitle:     row.QuestTitle,
			QuestLoop:      row.QuestLoop,
			Repo: RepoSnapshot{
				Identity: row.RepoIdentity,
				Name:     row.RepoName,
				Color:    row.RepoColor,
			},
			DisplayColor: row.DisplayColor,
		}
	}
	return out
}

func elapsedMS(observedAt, since time.Time) int64 {
	if since.IsZero() || observedAt.Before(since) {
		return 0
	}
	return observedAt.Sub(since).Milliseconds()
}

func timePtr(t time.Time) *time.Time {
	if t.IsZero() {
		return nil
	}
	utc := t.UTC()
	return &utc
}

func manifestSessionType(m state.Manifest) string {
	if m.SessionType == "master" {
		return "master"
	}
	if m.ExtraString("parent_session") != "" {
		return "worker"
	}
	return "standalone"
}

func runtimeSidecar() *gate.Sidecar {
	home := quest.Home()
	if home == "" {
		return nil
	}
	return gate.NewSidecar(filepath.Join(home, "runtime"))
}
