//go:build linux || darwin

// Package serve exposes read-only questmaster runtime snapshots over a local
// transport. It is a presentation layer over the existing quest, runtime, and
// tracker readers; it never owns orchestration state.
package serve

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"sync"
	"time"

	"github.com/alexivison/questmaster/internal/quests/gate"
	"github.com/alexivison/questmaster/internal/quests/quest"
	qruntime "github.com/alexivison/questmaster/internal/quests/runtime"
	"github.com/alexivison/questmaster/internal/sessionactivity"
	"github.com/alexivison/questmaster/internal/state"
	"github.com/alexivison/questmaster/internal/tmux"
	"github.com/alexivison/questmaster/internal/tracker"
)

// Snapshotter builds the read-only data surfaces served to clients.
type Snapshotter struct {
	store      *state.Store
	questStore questReadStore
	tmuxClient *tmux.Client
	fetcher    tracker.SessionFetcher
	now        func() time.Time

	mu           sync.Mutex
	quests       cachedQuestSet
	runtimeCache map[string]quest.Runtime
	trackerCache *TrackerSnapshot
}

type questReadStore interface {
	Dir() string
	List() ([]quest.Quest, error)
	Load(string) (*quest.Quest, error)
	Fingerprint() (string, error)
}

type cachedQuestSet struct {
	fingerprint string
	loadedAll   bool
	byID        map[string]quest.Quest
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
		questStore: quest.DefaultStore(),
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

// QuestDir returns the durable quest JSON/HTML store read by serve.
func (s *Snapshotter) QuestDir() string {
	return s.questsStore().Dir()
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
	return s.BoardForChange(Change{})
}

func (s *Snapshotter) BoardForChange(change Change) (BoardSnapshot, error) {
	observedAt := s.now().UTC()
	qs, err := s.cachedQuests(change)
	if err != nil {
		return BoardSnapshot{}, err
	}
	ids := make([]string, len(qs))
	for i, q := range qs {
		ids[i] = q.ID
	}
	runtimes := s.cachedRuntimes(ids, observedAt, change)

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
	return s.QuestForChange(id, Change{})
}

func (s *Snapshotter) QuestForChange(id string, change Change) (QuestSnapshot, error) {
	q, err := s.cachedQuest(id, change)
	if err != nil {
		return QuestSnapshot{}, err
	}
	rt := s.cachedRuntimes([]string{id}, s.now().UTC(), change)[id]
	return QuestSnapshot{Quest: q, Runtime: runtimeSnapshot(rt), ObservedAt: rt.ObservedAt}, nil
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

func (s *Snapshotter) Invalidate(change Change) {
	if contains(change.Topics, topicTracker) {
		if change.Clock && len(change.SessionIDs) == 0 {
			return
		}
		if s.tmuxClient != nil {
			s.tmuxClient.ClearListSessionsCache()
		}
		if len(change.SessionIDs) == 0 {
			s.clearTrackerCache()
		}
	}
}

func (s *Snapshotter) clearTrackerCache() {
	s.mu.Lock()
	s.trackerCache = nil
	s.mu.Unlock()
}

func (s *Snapshotter) questsStore() questReadStore {
	if s == nil || s.questStore == nil {
		return quest.DefaultStore()
	}
	return s.questStore
}

func (s *Snapshotter) cachedQuests(change Change) ([]quest.Quest, error) {
	store := s.questsStore()
	fp, fpErr := store.Fingerprint()

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.quests.byID == nil {
		s.quests.byID = map[string]quest.Quest{}
	}
	if fpErr == nil && s.quests.loadedAll && fp == s.quests.fingerprint {
		return s.sortedCachedQuestsLocked(), nil
	}
	if fpErr == nil && s.quests.loadedAll && len(change.QuestIDs) > 0 {
		for _, id := range change.QuestIDs {
			q, err := store.Load(id)
			if err != nil {
				delete(s.quests.byID, id)
				delete(s.runtimeCache, id)
				continue
			}
			s.quests.byID[id] = *q
		}
		s.quests.fingerprint = fp
		return s.sortedCachedQuestsLocked(), nil
	}

	qs, err := store.List()
	if err != nil {
		return nil, err
	}
	s.quests.byID = make(map[string]quest.Quest, len(qs))
	for _, q := range qs {
		s.quests.byID[q.ID] = q
	}
	if fpErr == nil {
		s.quests.fingerprint = fp
	}
	s.quests.loadedAll = true
	return s.sortedCachedQuestsLocked(), nil
}

func (s *Snapshotter) cachedQuest(id string, change Change) (*quest.Quest, error) {
	store := s.questsStore()
	fp, fpErr := store.Fingerprint()

	s.mu.Lock()
	defer s.mu.Unlock()
	if s.quests.byID == nil {
		s.quests.byID = map[string]quest.Quest{}
	}
	if fpErr == nil && fp == s.quests.fingerprint {
		if q, ok := s.quests.byID[id]; ok {
			q := q
			return &q, nil
		}
		if s.quests.loadedAll {
			return store.Load(id)
		}
	}
	q, err := store.Load(id)
	if err != nil {
		delete(s.quests.byID, id)
		delete(s.runtimeCache, id)
		return nil, err
	}
	s.quests.byID[id] = *q
	if fpErr == nil {
		s.quests.fingerprint = fp
	}
	return q, nil
}

func (s *Snapshotter) sortedCachedQuestsLocked() []quest.Quest {
	out := make([]quest.Quest, 0, len(s.quests.byID))
	for _, q := range s.quests.byID {
		out = append(out, q)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

func (s *Snapshotter) cachedRuntimes(ids []string, observedAt time.Time, change Change) map[string]quest.Runtime {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.runtimeCache == nil {
		s.runtimeCache = map[string]quest.Runtime{}
	}

	refreshIDs := append([]string(nil), ids...)
	if len(change.Topics) > 0 && len(change.QuestIDs) > 0 && len(s.runtimeCache) > 0 {
		wanted := make(map[string]struct{}, len(ids))
		for _, id := range ids {
			wanted[id] = struct{}{}
		}
		refreshIDs = make([]string, 0, len(change.QuestIDs))
		for _, id := range change.QuestIDs {
			if _, ok := wanted[id]; ok {
				refreshIDs = append(refreshIDs, id)
			}
		}
	}
	if len(change.Topics) == 0 || len(s.runtimeCache) == 0 || len(refreshIDs) > 0 {
		for id, rt := range qruntime.Snapshot(runtimeSidecar(), refreshIDs, observedAt) {
			s.runtimeCache[id] = rt
		}
	}

	out := make(map[string]quest.Runtime, len(ids))
	for _, id := range ids {
		rt, ok := s.runtimeCache[id]
		if !ok {
			rt = qruntime.Snapshot(runtimeSidecar(), []string{id}, observedAt)[id]
			s.runtimeCache[id] = rt
		}
		out[id] = rt
	}
	return out
}

// Tracker returns the tracker row model with hook-driven activity applied.
func (s *Snapshotter) Tracker(context.Context) (TrackerSnapshot, error) {
	return s.refreshTracker()
}

func (s *Snapshotter) TrackerForChange(change Change) (TrackerSnapshot, error) {
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
		if err != nil || ss == nil || next.Sessions[idx].QuestID != ss.QuestID {
			return s.refreshTracker()
		}
		applySessionState(&next.Sessions[idx], sessionID, ss, observedAt)
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
	if row.QuestID != ss.QuestID {
		return false, fmt.Errorf("quest attachment changed for %s", row.ID)
	}
	applySessionState(row, row.ID, ss, observedAt)
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
		a.QuestID == b.QuestID &&
		reflect.DeepEqual(a.QuestLoop, b.QuestLoop)
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
		Sessions:   sessionSnapshots(snap.Sessions, observedAt),
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

func applySessionState(row *SessionSnapshot, sessionID string, ss *state.SessionState, observedAt time.Time) {
	if row == nil || ss == nil {
		return
	}
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
	row.QuestID = ss.QuestID
	row.QuestLoop = qruntime.LoopRuntime(sessionID, ss.QuestLoop)
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

func sessionSnapshots(rows []tracker.SessionRow, observedAt time.Time) []SessionSnapshot {
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
	return tracker.SessionTypeForManifest(m)
}

func runtimeSidecar() *gate.Sidecar {
	home := quest.Home()
	if home == "" {
		return nil
	}
	return gate.NewSidecar(filepath.Join(home, "runtime"))
}
