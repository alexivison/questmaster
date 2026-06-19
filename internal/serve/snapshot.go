//go:build linux || darwin

// Package serve exposes read-only questmaster runtime snapshots over a local
// transport. It is a presentation layer over the existing quest, runtime, and
// tracker readers; it never owns orchestration state.
package serve

import (
	"context"
	"path/filepath"
	"time"

	"github.com/alexivison/questmaster/internal/quests/gate"
	"github.com/alexivison/questmaster/internal/quests/quest"
	qruntime "github.com/alexivison/questmaster/internal/quests/runtime"
	"github.com/alexivison/questmaster/internal/sessionactivity"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tui"
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
	Quest   quest.Quest   `json:"quest"`
	Runtime quest.Runtime `json:"runtime"`
}

// QuestSnapshot is the native quest viewer's read model.
type QuestSnapshot struct {
	Quest   *quest.Quest  `json:"quest"`
	Runtime quest.Runtime `json:"runtime"`
}

// TrackerSnapshot is the native tracker's read model.
type TrackerSnapshot struct {
	ObservedAt time.Time         `json:"observed_at"`
	Current    *CurrentSession   `json:"current,omitempty"`
	Sessions   []SessionSnapshot `json:"sessions"`
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
			out.Groups[i].Quests[j] = BoardQuest{Quest: q, Runtime: runtimes[q.ID]}
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
	return QuestSnapshot{Quest: q, Runtime: rt}, nil
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
