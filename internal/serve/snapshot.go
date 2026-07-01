//go:build linux || darwin

// Package serve exposes read-only questmaster runtime snapshots over a local
// transport. It is a presentation layer over existing runtime and tracker
// readers; it never owns orchestration state.
package serve

import (
	"context"
	"fmt"
	"sync"
	"time"

	"github.com/alexivison/questmaster/internal/sessionactivity"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tracker"
)

// Snapshotter builds the read-only data surfaces served to clients.
type Snapshotter struct {
	store        *state.Store
	tmuxClient   *tmux.Client
	fetcher      tracker.SessionFetcher
	now          func() time.Time
	mu           sync.Mutex
	trackerCache *TrackerSnapshot
}

// NewSnapshotter creates a snapshot reader from existing qm services.
func NewSnapshotter(store *state.Store, tmuxClient *tmux.Client, now func() time.Time) *Snapshotter {
	if store == nil {
		store = state.OpenStore(state.StateRoot())
	}
	if tmuxClient == nil {
		tmuxClient = tmux.NewExecClient()
	}
	tmuxClient.CacheListSessions(time.Second)
	if now == nil {
		now = time.Now
	}
	return &Snapshotter{
		store:      store,
		tmuxClient: tmuxClient,
		fetcher:    tracker.NewLiveSessionFetcher(tmuxClient, store),
		now:        now,
	}
}

// StateRoot returns the durable session-state root read by serve.
func (s *Snapshotter) StateRoot() string {
	if s == nil || s.store == nil {
		return state.StateRoot()
	}
	return s.store.Root()
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

// ArtifactSnapshot is a tracker-visible runtime artifact reference.
type ArtifactSnapshot struct {
	Kind    string `json:"kind"`
	Path    string `json:"path"`
	Label   string `json:"label"`
	AddedAt string `json:"added_at"`
	Missing bool   `json:"missing,omitempty"`
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
	Artifacts      []ArtifactSnapshot `json:"artifacts,omitempty"`
	Repo           RepoSnapshot       `json:"repo,omitempty"`
	DisplayColor   string             `json:"display_color,omitempty"`
}

// RepoSnapshot carries tracker repo grouping metadata.
type RepoSnapshot struct {
	Identity string `json:"identity,omitempty"`
	Name     string `json:"name,omitempty"`
	Color    string `json:"color,omitempty"`
}

func (s *Snapshotter) Invalidate(change Change) {
	if contains(change.Topics, topicTracker) {
		if change.Clock && len(change.SessionIDs) == 0 {
			return
		}
		if s.tmuxClient != nil {
			s.tmuxClient.ClearListSessionsCache()
		}
		if change.BroadTracker || len(change.SessionIDs) == 0 {
			s.clearTrackerCache()
		}
	}
}

func (s *Snapshotter) clearTrackerCache() {
	s.mu.Lock()
	s.trackerCache = nil
	s.mu.Unlock()
}

func (s *Snapshotter) TrackerForChange(change Change) (TrackerSnapshot, error) {
	// A broad (session-agnostic) tracker change such as a repo-color edit only
	// surfaces through the full rebuild path; the per-session delta below never
	// touches row.Repo / row.DisplayColor. Honor it even when it coalesced with
	// per-session changes that left SessionIDs populated.
	if change.BroadTracker {
		return s.refreshTracker()
	}
	if change.Clock && len(change.SessionIDs) == 0 {
		return s.clockTracker()
	}
	if len(change.SessionIDs) == 0 {
		return s.refreshTracker()
	}
	s.mu.Lock()
	cached := s.trackerCache
	s.mu.Unlock()
	if cached == nil {
		return s.fullTracker()
	}
	liveSessions, err := s.liveSessionSet()
	if err != nil {
		return s.refreshTracker()
	}

	next := cloneTrackerSnapshot(*cached)
	observedAt := s.now().UTC()
	if observedAt.IsZero() {
		observedAt = time.Now().UTC()
	}
	next.ObservedAt = observedAt
	for _, sessionID := range change.SessionIDs {
		idx := trackerSessionIndex(next.Sessions, sessionID)
		if idx < 0 {
			return s.refreshTracker()
		}
		if _, live := liveSessions[sessionID]; live {
			next.Sessions[idx].Status = "active"
		} else {
			next.Sessions[idx].Status = "stopped"
		}
		if next.Sessions[idx].Status == "active" {
			_, _ = state.MarkSessionObserved(sessionID, observedAt)
		}
		ss, err := state.LoadSessionStateAt(s.StateRoot(), sessionID)
		if err != nil || ss == nil {
			return s.refreshTracker()
		}
		s.applySessionState(&next.Sessions[idx], sessionID, ss, observedAt)
	}

	s.mu.Lock()
	s.trackerCache = &next
	s.mu.Unlock()
	return next, nil
}

func (s *Snapshotter) clockTracker() (TrackerSnapshot, error) {
	s.mu.Lock()
	cached := s.trackerCache
	s.mu.Unlock()
	if cached == nil {
		return s.fullTracker()
	}

	next := cloneTrackerSnapshot(*cached)
	observedAt := s.now().UTC()
	if observedAt.IsZero() {
		observedAt = time.Now().UTC()
	}
	changed := false
	for i := range next.Sessions {
		if next.Sessions[i].Status != "active" {
			continue
		}
		rowChanged, err := s.reconcileClockTrackerRow(&next.Sessions[i], observedAt)
		if err != nil {
			return s.refreshTracker()
		}
		if !rowChanged {
			continue
		}
		changed = true
	}
	if !changed {
		return cloneTrackerSnapshot(*cached), nil
	}
	next.ObservedAt = observedAt

	s.mu.Lock()
	s.trackerCache = &next
	s.mu.Unlock()
	return next, nil
}

func (s *Snapshotter) reconcileClockTrackerRow(row *SessionSnapshot, observedAt time.Time) (bool, error) {
	before := *row
	_, _ = state.MarkSessionObserved(row.ID, observedAt)
	ss, err := state.LoadSessionStateAt(s.StateRoot(), row.ID)
	if err != nil {
		return false, err
	}
	if ss == nil {
		return false, nil
	}
	s.applySessionState(row, row.ID, ss, observedAt)
	if sameClockTrackerRow(before, *row) {
		*row = before
		return false, nil
	}
	return true, nil
}

func sameClockTrackerRow(a, b SessionSnapshot) bool {
	return a.Status == b.Status &&
		a.State == b.State &&
		a.LatestActivity == b.LatestActivity &&
		a.LastKind == b.LastKind &&
		artifactsEqual(a.Artifacts, b.Artifacts)
}

func (s *Snapshotter) liveSessionSet() (map[string]struct{}, error) {
	if s.tmuxClient == nil {
		return nil, fmt.Errorf("tmux client is required")
	}
	sessions, err := s.tmuxClient.ListSessions(context.Background())
	if err != nil {
		return nil, err
	}
	live := make(map[string]struct{}, len(sessions))
	for _, sessionID := range sessions {
		live[sessionID] = struct{}{}
	}
	return live, nil
}

func (s *Snapshotter) refreshTracker() (TrackerSnapshot, error) {
	s.clearTrackerCache()
	return s.fullTracker()
}

func (s *Snapshotter) fullTracker() (TrackerSnapshot, error) {
	current := s.currentSession()
	snap, err := s.fetcher(current)
	if err != nil {
		return TrackerSnapshot{}, err
	}
	observedAt := snap.ObservedAt.UTC()
	if observedAt.IsZero() {
		observedAt = s.now().UTC()
	}
	s.observeTrackerRows(snap.Sessions, observedAt)
	return s.cacheTracker(TrackerSnapshot{
		ObservedAt: observedAt,
		Current:    currentSessionSnapshot(current),
		Sessions:   s.sessionSnapshots(snap.Sessions, observedAt),
	}), nil
}

func (s *Snapshotter) cacheTracker(snapshot TrackerSnapshot) TrackerSnapshot {
	cached := cloneTrackerSnapshot(snapshot)
	s.mu.Lock()
	s.trackerCache = &cached
	s.mu.Unlock()
	return snapshot
}

func (s *Snapshotter) observeTrackerRows(rows []tracker.SessionRow, observedAt time.Time) {
	for _, row := range rows {
		if row.Status == "active" {
			_, _ = state.MarkSessionObserved(row.ID, observedAt)
		}
	}
}

func cloneTrackerSnapshot(snapshot TrackerSnapshot) TrackerSnapshot {
	snapshot.Sessions = append([]SessionSnapshot(nil), snapshot.Sessions...)
	for i := range snapshot.Sessions {
		snapshot.Sessions[i].Artifacts = append([]ArtifactSnapshot(nil), snapshot.Sessions[i].Artifacts...)
	}
	return snapshot
}

func trackerSessionIndex(rows []SessionSnapshot, sessionID string) int {
	for i := range rows {
		if rows[i].ID == sessionID {
			return i
		}
	}
	return -1
}

func (s *Snapshotter) applySessionState(row *SessionSnapshot, sessionID string, ss *state.SessionState, observedAt time.Time) {
	if row == nil || ss == nil {
		return
	}
	row.Artifacts = artifactSnapshots(s.sessionArtifacts(sessionID))
	if row.Status != "active" {
		row.State = "stopped"
		row.ElapsedMS = 0
		row.ElapsedSince = nil
		return
	}
	result := sessionactivity.FromState(ss)
	if result.State != "" {
		row.State = result.State
	}
	if result.LastKind != "" {
		row.LastKind = result.LastKind
	}
	if result.Activity != "" {
		row.LatestActivity = result.Activity
	}
	elapsedSince := result.WorkingSince
	if elapsedSince.IsZero() {
		elapsedSince = result.LastEvent
	}
	row.ElapsedMS = elapsedMS(observedAt, elapsedSince)
	row.ElapsedSince = timePtr(elapsedSince)
}

func (s *Snapshotter) currentSession() tracker.SessionInfo {
	id := state.SessionIDFromEnv()
	if id == "" || !state.IsValidSessionID(id) {
		return tracker.SessionInfo{}
	}
	m, err := s.store.Read(id)
	if err != nil {
		return tracker.SessionInfo{ID: id}
	}
	return tracker.SessionInfo{
		ID:          id,
		Title:       m.Title,
		Cwd:         m.Cwd,
		SessionType: manifestSessionType(m),
		Manifest:    m,
	}
}

func currentSessionSnapshot(current tracker.SessionInfo) *CurrentSession {
	if current.ID == "" {
		return nil
	}
	return &CurrentSession{
		ID:          current.ID,
		Title:       current.Title,
		SessionType: current.SessionType,
	}
}

func (s *Snapshotter) sessionSnapshots(rows []tracker.SessionRow, observedAt time.Time) []SessionSnapshot {
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
	stateRoot := s.StateRoot()
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
			Artifacts:      artifactSnapshots(s.sessionArtifactsAt(stateRoot, row.ID)),
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

func (s *Snapshotter) sessionArtifacts(sessionID string) []state.Artifact {
	return s.sessionArtifactsAt(s.StateRoot(), sessionID)
}

func (s *Snapshotter) sessionArtifactsAt(root, sessionID string) []state.Artifact {
	artifacts, err := state.LoadArtifactsAt(root, sessionID)
	if err != nil {
		return nil
	}
	return artifacts
}

func artifactSnapshots(artifacts []state.Artifact) []ArtifactSnapshot {
	sorted := state.SortedArtifacts(artifacts)
	if len(sorted) == 0 {
		return nil
	}
	out := make([]ArtifactSnapshot, 0, len(sorted))
	for _, artifact := range sorted {
		out = append(out, ArtifactSnapshot{
			Kind:    artifact.Kind,
			Path:    artifact.Path,
			Label:   artifact.Label,
			AddedAt: artifact.AddedAt,
			Missing: state.ArtifactMissing(artifact.Path),
		})
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
	return tracker.SessionTypeForManifest(m)
}

func artifactsEqual(a, b []ArtifactSnapshot) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
