//go:build linux || darwin

package state

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"syscall"
	"time"
)

// SchemaVersion is the current PaneState/SessionState schema version. Hook
// payloads that load a SessionState with a different Version overwrite it;
// readers (the tracker) treat foreign-version state as `unknown`.
const SchemaVersion = 1

// StateJSONLMaxSize is the rotation threshold for state.jsonl. When the
// file exceeds this size, the writer rotates it to state.jsonl.1 and
// starts a fresh log. One historical file is kept.
const StateJSONLMaxSize = 1 << 20 // 1 MiB

// DoneToIdleGrace is how long a completed agent turn stays visibly "done"
// before an observing tracker can fold it back to idle.
const DoneToIdleGrace = 10 * time.Second

const ArtifactKindHTML = "html"

var ensuredSessionStateDirs sync.Map

// Artifact is a session-scoped runtime reference to a generated file.
type Artifact struct {
	Kind    string `json:"kind"`
	Path    string `json:"path"`
	Label   string `json:"label,omitempty"`
	AddedAt string `json:"added_at"`
}

// SessionState is the authoritative per-session state snapshot written by
// hooks and read by the tracker. One file per session at
// <state_root>/<session_id>/state.json.
type SessionState struct {
	SessionID string               `json:"session_id"`
	Version   int                  `json:"version"`
	Panes     map[string]PaneState `json:"panes"`
	SeenAt    time.Time            `json:"seen_at"`

	// QuestID links a session to an active quest. It is stamped on explicit
	// attach/spawn, including workers, and cleared on detach. "Sessions on a
	// quest" is derived by scanning this field, never stored on the quest.
	// Preserved across hook writes because hooks read-modify-write the whole
	// SessionState (UpdateSessionState).
	QuestID string `json:"quest_id,omitempty"`

	// QuestLoop is an advisory marker written while `qm quest loop` is armed
	// for this session. The foreground process is authoritative; this marker
	// only drives visibility and double-arm refusal.
	QuestLoop *QuestLoopState `json:"quest_loop,omitempty"`

	// Artifacts are runtime-only viewer references for this session. The bytes
	// remain at Path; quest attachments are not used for this transport.
	Artifacts []Artifact `json:"artifacts,omitempty"`
}

// QuestLoopState is the renderer-visible marker for an armed quest loop.
// Phase is the loop's current step (waiting | checking | paused), written at
// each transition so the board/tracker can show what the armed loop is doing
// between iterations. Like the rest of the marker it is advisory only.
type QuestLoopState struct {
	Since       time.Time `json:"since"`
	Iterations  int       `json:"iterations"`
	LastVerdict string    `json:"last_verdict,omitempty"`
	Phase       string    `json:"phase,omitempty"`
}

// PaneState is the renderer-visible state for one role within a session.
// WorkingSince timestamps the moment State transitioned to "working" and
// is preserved across PreToolUse/PostToolUse cycles within the same turn,
// so the tracker can render an ever-growing "working 2m14s" suffix.
// Agent-specific carry-through fields are populated only by providers that
// emit structured hook metadata.
type PaneState struct {
	Role         string    `json:"role"`
	Agent        string    `json:"agent"`
	State        string    `json:"state"`
	Activity     string    `json:"activity"`
	Tool         string    `json:"tool,omitempty"`
	Seq          int64     `json:"seq"`
	LastEvent    time.Time `json:"last_event"`
	LastKind     string    `json:"last_kind"`
	WorkingSince time.Time `json:"working_since,omitempty"`

	Recent            []string `json:"recent,omitempty"`
	SessionFile       string   `json:"session_file,omitempty"`
	PiSessionID       string   `json:"pi_session_id,omitempty"`
	OpenCodeSessionID string   `json:"opencode_session_id,omitempty"`

	// PendingPartMsgID/PendingPartText buffer an opencode message part whose
	// author role is not yet known. The text is promoted to Activity/Recent only
	// once the matching assistant message.updated arrives, so a user's prompt is
	// never surfaced as the worker's activity.
	PendingPartMsgID string `json:"pending_part_msg_id,omitempty"`
	PendingPartText  string `json:"pending_part_text,omitempty"`
}

// StateRoot resolves the directory that holds per-session state. Honors
// $QUESTMASTER_STATE_ROOT, then falls back to ~/.questmaster-state.
// Returns the empty string when neither an override nor $HOME is set
// (caller treats that as a no-op condition).
func StateRoot() string {
	if root := os.Getenv(StateRootEnv); root != "" {
		return root
	}
	if home := os.Getenv("HOME"); home != "" {
		return filepath.Join(home, ".questmaster-state")
	}
	return ""
}

// SessionStateDir returns <root>/<id>. Caller must ensure id is valid.
func SessionStateDir(root, id string) string {
	return filepath.Join(root, id)
}

// SessionStatePath returns the state.json path for the session.
func SessionStatePath(root, id string) string {
	return filepath.Join(SessionStateDir(root, id), "state.json")
}

// SessionStateLogPath returns the state.jsonl path for the session.
func SessionStateLogPath(root, id string) string {
	return filepath.Join(SessionStateDir(root, id), "state.jsonl")
}

// SessionArtifactsPath returns the command-owned runtime artifact sidecar path
// for the session. Hooks own state.json; artifact commands own this file.
func SessionArtifactsPath(root, id string) string {
	return filepath.Join(SessionStateDir(root, id), "artifacts.json")
}

// LifecycleLogPath returns the root-level lifecycle event log. It survives
// session-state directory cleanup, unlike <session>/state.jsonl.
func LifecycleLogPath(root string) string {
	return filepath.Join(root, "lifecycle.jsonl")
}

// LifecycleLogLockPath returns the root-level lifecycle log lock path.
func LifecycleLogLockPath(root string) string {
	return filepath.Join(root, "lifecycle.jsonl.lock")
}

// SessionStateLockPath returns the flock path. We lock a sibling file
// rather than state.json itself so the atomic rename of state.json never
// races a still-held lock fd.
func SessionStateLockPath(root, id string) string {
	return filepath.Join(SessionStateDir(root, id), "state.json.lock")
}

// LoadSessionState reads the state.json for a session. Returns (nil, nil)
// if the file does not exist (the renderer should treat this as
// "unknown"). The state root is resolved from $QUESTMASTER_STATE_ROOT
// or $HOME.
func LoadSessionState(id string) (*SessionState, error) {
	return LoadSessionStateAt(StateRoot(), id)
}

// LoadSessionStateAt is LoadSessionState with the state root supplied by the
// caller. A refresh loop that already knows the root (e.g. the tracker's
// fetcher, iterating every session each tick) uses this to skip the per-call
// StateRoot() — two os.Getenv plus a join — on every session.
func LoadSessionStateAt(root, id string) (*SessionState, error) {
	if !IsValidSessionID(id) {
		return nil, fmt.Errorf("invalid session id: %q", id)
	}
	if root == "" {
		return nil, nil
	}
	return loadSessionStateAt(root, id)
}

func loadSessionStateAt(root, id string) (*SessionState, error) {
	path := SessionStatePath(root, id)
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	return decodeSessionState(data)
}

func decodeSessionState(data []byte) (*SessionState, error) {
	var s SessionState
	if err := json.Unmarshal(data, &s); err != nil {
		return nil, fmt.Errorf("decode session state: %w", err)
	}
	if s.Panes == nil {
		s.Panes = map[string]PaneState{}
	}
	return &s, nil
}

// SaveSessionState writes the state.json for a session atomically. The
// write is serialized via flock on a sibling lockfile.
func SaveSessionState(id string, ss *SessionState) error {
	if !IsValidSessionID(id) {
		return fmt.Errorf("invalid session id: %q", id)
	}
	if ss == nil {
		return errors.New("nil session state")
	}
	root := StateRoot()
	if root == "" {
		return errors.New("no state root resolved (set QUESTMASTER_STATE_ROOT or HOME)")
	}
	return withStateLock(root, id, func() error {
		return writeSessionStateLocked(root, id, ss)
	})
}

// UpdateSessionState performs a locked read-modify-write. mutate runs
// against the freshly-loaded state inside the critical section. Returning
// false from mutate aborts the write (used when the freshly-read state no
// longer satisfies the precondition the caller checked optimistically).
//
// This is the only safe way to apply tracker-side mutations like
// done → idle: a naive Load → mutate → Save races against hooks because
// the load happens outside the lock.
func UpdateSessionState(id string, mutate func(*SessionState) bool) error {
	if !IsValidSessionID(id) {
		return fmt.Errorf("invalid session id: %q", id)
	}
	if mutate == nil {
		return errors.New("nil mutate function")
	}
	root := StateRoot()
	if root == "" {
		return errors.New("no state root resolved")
	}
	return withStateLock(root, id, func() error {
		ss, err := loadSessionStateAt(root, id)
		if err != nil {
			return err
		}
		if ss == nil {
			ss = &SessionState{
				SessionID: id,
				Version:   SchemaVersion,
				Panes:     map[string]PaneState{},
			}
		}
		if !mutate(ss) {
			return nil
		}
		return writeSessionStateLocked(root, id, ss)
	})
}

type artifactSidecar struct {
	Artifacts []Artifact `json:"artifacts,omitempty"`
}

// LoadArtifacts reads command-owned runtime artifact references. It falls back
// to legacy state.json artifacts so refs added by older feature builds are not
// stranded before the next artifact command migrates them to the sidecar.
func LoadArtifacts(sessionID string) ([]Artifact, error) {
	return LoadArtifactsAt(StateRoot(), sessionID)
}

// LoadArtifactsAt is LoadArtifacts with an explicit state root.
func LoadArtifactsAt(root, sessionID string) ([]Artifact, error) {
	if !IsValidSessionID(sessionID) {
		return nil, fmt.Errorf("invalid session id: %q", sessionID)
	}
	if root == "" {
		return nil, nil
	}
	return loadArtifactsAt(root, sessionID)
}

func UpsertArtifact(sessionID string, artifact Artifact) error {
	artifact = normalizeArtifact(artifact)
	if artifact.Path == "" {
		return errors.New("artifact path is required")
	}
	if !filepath.IsAbs(artifact.Path) {
		return fmt.Errorf("artifact path must be absolute: %s", artifact.Path)
	}
	if !IsValidSessionID(sessionID) {
		return fmt.Errorf("invalid session id: %q", sessionID)
	}
	root := StateRoot()
	if root == "" {
		return errors.New("no state root resolved")
	}
	return withStateLock(root, sessionID, func() error {
		artifacts, err := loadArtifactsAt(root, sessionID)
		if err != nil {
			return err
		}
		for i := range artifacts {
			if artifacts[i].Path == artifact.Path {
				artifacts[i] = artifact
				return writeArtifactsLocked(root, sessionID, artifacts)
			}
		}
		artifacts = append(artifacts, artifact)
		return writeArtifactsLocked(root, sessionID, artifacts)
	})
}

func RemoveArtifact(sessionID, path string) (bool, error) {
	if path == "" {
		return false, errors.New("artifact path is required")
	}
	path = filepath.Clean(path)
	if !IsValidSessionID(sessionID) {
		return false, fmt.Errorf("invalid session id: %q", sessionID)
	}
	root := StateRoot()
	if root == "" {
		return false, errors.New("no state root resolved")
	}
	removed := false
	err := withStateLock(root, sessionID, func() error {
		artifacts, err := loadArtifactsAt(root, sessionID)
		if err != nil {
			return err
		}
		next := make([]Artifact, 0, len(artifacts))
		for _, artifact := range artifacts {
			if artifact.Path == path {
				removed = true
				continue
			}
			next = append(next, artifact)
		}
		if !removed {
			return nil
		}
		return writeArtifactsLocked(root, sessionID, next)
	})
	return removed, err
}

func loadArtifactsAt(root, sessionID string) ([]Artifact, error) {
	data, err := os.ReadFile(SessionArtifactsPath(root, sessionID))
	if err == nil {
		var payload artifactSidecar
		if err := json.Unmarshal(data, &payload); err != nil {
			return nil, fmt.Errorf("decode artifacts sidecar: %w", err)
		}
		return SortedArtifacts(payload.Artifacts), nil
	}
	if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}
	ss, err := loadSessionStateAt(root, sessionID)
	if err != nil || ss == nil {
		return nil, err
	}
	return SortedArtifacts(ss.Artifacts), nil
}

func writeArtifactsLocked(root, sessionID string, artifacts []Artifact) error {
	if err := ensureSessionStateDir(root, sessionID); err != nil {
		return err
	}
	data, err := json.Marshal(artifactSidecar{Artifacts: SortedArtifacts(artifacts)})
	if err != nil {
		return fmt.Errorf("marshal artifacts sidecar: %w", err)
	}
	data = append(data, '\n')
	path := SessionArtifactsPath(root, sessionID)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write tmp artifacts: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename artifacts.json: %w", err)
	}
	return nil
}

func SortedArtifacts(artifacts []Artifact) []Artifact {
	if len(artifacts) == 0 {
		return nil
	}
	out := make([]Artifact, 0, len(artifacts))
	for _, artifact := range artifacts {
		artifact = normalizeArtifact(artifact)
		if artifact.Path == "" {
			continue
		}
		out = append(out, artifact)
	}
	sort.SliceStable(out, func(i, j int) bool {
		left, leftOK := parseArtifactTime(out[i].AddedAt)
		right, rightOK := parseArtifactTime(out[j].AddedAt)
		if leftOK && rightOK && !left.Equal(right) {
			return left.After(right)
		}
		if out[i].AddedAt != out[j].AddedAt {
			return out[i].AddedAt > out[j].AddedAt
		}
		return out[i].Path < out[j].Path
	})
	return out
}

func ArtifactMissing(path string) bool {
	if path == "" {
		return true
	}
	_, err := os.Stat(path)
	return err != nil
}

func normalizeArtifact(artifact Artifact) Artifact {
	if artifact.Path != "" {
		artifact.Path = filepath.Clean(artifact.Path)
	}
	if artifact.Kind == "" {
		artifact.Kind = ArtifactKindHTML
	}
	if artifact.Label == "" && artifact.Path != "" {
		artifact.Label = filepath.Base(artifact.Path)
	}
	if artifact.AddedAt == "" {
		artifact.AddedAt = time.Now().UTC().Format(time.RFC3339Nano)
	}
	return artifact
}

func parseArtifactTime(raw string) (time.Time, bool) {
	if raw == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339Nano, raw)
	return t, err == nil
}

// MarkSessionObserved applies tracker-side observation to an existing
// state.json. It never creates state for hookless sessions.
func MarkSessionObserved(id string, now time.Time) (bool, error) {
	if now.IsZero() {
		now = time.Now()
	}
	now = now.UTC()

	changed := false
	err := updateExistingSessionState(id, func(ss *SessionState) bool {
		pane, ok := ss.Panes["primary"]
		if !ok || pane.State != "done" {
			return false
		}
		if !pane.LastEvent.IsZero() && now.Sub(pane.LastEvent) < DoneToIdleGrace {
			return false
		}

		ss.SeenAt = now
		pane.State = "idle"
		pane.WorkingSince = time.Time{}
		ss.Panes["primary"] = pane
		changed = true
		return true
	})
	return changed, err
}

func updateExistingSessionState(id string, mutate func(*SessionState) bool) error {
	if !IsValidSessionID(id) {
		return fmt.Errorf("invalid session id: %q", id)
	}
	if mutate == nil {
		return errors.New("nil mutate function")
	}
	root := StateRoot()
	if root == "" {
		return errors.New("no state root resolved")
	}
	return withStateLock(root, id, func() error {
		ss, err := loadSessionStateAt(root, id)
		if err != nil || ss == nil {
			return err
		}
		if !mutate(ss) {
			return nil
		}
		return writeSessionStateLocked(root, id, ss)
	})
}

func writeSessionStateLocked(root, id string, ss *SessionState) error {
	if ss.SessionID == "" {
		ss.SessionID = id
	}
	if ss.Version == 0 {
		ss.Version = SchemaVersion
	}
	if ss.Panes == nil {
		ss.Panes = map[string]PaneState{}
	}
	if err := ensureSessionStateDir(root, id); err != nil {
		return err
	}
	data, err := json.Marshal(ss)
	if err != nil {
		return fmt.Errorf("marshal session state: %w", err)
	}
	data = append(data, '\n')
	path := SessionStatePath(root, id)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("write tmp state: %w", err)
	}
	if err := os.Rename(tmp, path); err != nil {
		os.Remove(tmp)
		return fmt.Errorf("rename state.json: %w", err)
	}
	return nil
}

// InitStartingState seeds state.json with State="starting" / Activity="started"
// for each provided pane (roleName → agentName, e.g. {"primary": "codex"}).
// Skips any pane that already has a non-empty State so the agent's first
// hook (which fires moments later) is never overwritten. This eliminates
// the brief "unknown" the tracker would otherwise render between spawn and
// the SessionStart hook.
func InitStartingState(id string, agentsByRole map[string]string) error {
	if len(agentsByRole) == 0 {
		return nil
	}
	now := time.Now().UTC()
	return UpdateSessionState(id, func(ss *SessionState) bool {
		changed := false
		ss.SeenAt = now
		for role, agentName := range agentsByRole {
			if role == "" || agentName == "" {
				continue
			}
			if pane, ok := ss.Panes[role]; ok && pane.State != "" {
				continue
			}
			ss.Panes[role] = PaneState{
				Role:      role,
				Agent:     agentName,
				State:     "starting",
				Activity:  "started",
				LastKind:  "SessionStart",
				LastEvent: now,
				Seq:       now.UnixNano(),
			}
			changed = true
		}
		return changed
	})
}

// StateEvent is one line of state.jsonl. Free-form fields beyond the
// fixed columns belong in Fields so consumers parsing the log don't have
// to keep up with a moving schema.
type StateEvent struct {
	Ts       time.Time              `json:"ts"`
	Agent    string                 `json:"agent"`
	Role     string                 `json:"role,omitempty"`
	Action   string                 `json:"action"`
	State    string                 `json:"state,omitempty"`
	Activity string                 `json:"activity,omitempty"`
	Tool     string                 `json:"tool,omitempty"`
	Kind     string                 `json:"kind,omitempty"`
	Fields   map[string]interface{} `json:"fields,omitempty"`
}

// AppendStateEvent appends to state.jsonl and rotates the file when it
// crosses StateJSONLMaxSize. The state root must already exist (the
// session-state directory is created lazily). Rotation drops the previous
// .1 file, so only one rolled file is retained on disk.
func AppendStateEvent(id string, ev StateEvent) error {
	if !IsValidSessionID(id) {
		return fmt.Errorf("invalid session id: %q", id)
	}
	root := StateRoot()
	if root == "" {
		return errors.New("no state root resolved")
	}
	return appendStateEventAt(root, id, ev)
}

// AppendLifecycleEvent appends a durable lifecycle event at the state root.
// Use it for events that must survive per-session cleanup, such as teardown.
func AppendLifecycleEvent(id string, ev StateEvent) error {
	if !IsValidSessionID(id) {
		return fmt.Errorf("invalid session id: %q", id)
	}
	root := StateRoot()
	if root == "" {
		return errors.New("no state root resolved")
	}
	if err := EnsurePrivateStateRoot(root); err != nil {
		return fmt.Errorf("create state root: %w", err)
	}
	if ev.Ts.IsZero() {
		ev.Ts = time.Now().UTC()
	}
	fields := make(map[string]interface{}, len(ev.Fields)+1)
	for k, v := range ev.Fields {
		fields[k] = v
	}
	fields["session_id"] = id
	ev.Fields = fields

	return withFileLock(LifecycleLogLockPath(root), func() error {
		return appendRotatingJSONL(LifecycleLogPath(root), ev)
	})
}

func appendStateEventAt(root, id string, ev StateEvent) error {
	if err := ensureSessionStateDir(root, id); err != nil {
		return err
	}
	if ev.Ts.IsZero() {
		ev.Ts = time.Now().UTC()
	}
	return withFileLock(SessionStateLockPath(root, id), func() error {
		return appendRotatingJSONL(SessionStateLogPath(root, id), ev)
	})
}

func appendRotatingJSONL(path string, ev StateEvent) error {
	if info, err := os.Stat(path); err == nil && info.Size() >= StateJSONLMaxSize {
		_ = os.Remove(path + ".1")
		_ = os.Rename(path, path+".1")
	}
	data, err := json.Marshal(ev)
	if err != nil {
		return fmt.Errorf("encode state event: %w", err)
	}
	data = append(data, '\n')
	f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("open state log: %w", err)
	}
	defer f.Close()
	if _, err := f.Write(data); err != nil {
		return fmt.Errorf("write state event: %w", err)
	}
	return nil
}

func withFileLock(lockPath string, fn func() error) error {
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("open log lock: %w", err)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return fmt.Errorf("acquire log lock: %w", err)
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN) //nolint:errcheck
	return fn()
}

// withStateLock acquires an exclusive flock on the per-session lockfile
// and runs fn while holding it. The lockfile is created on first use.
//
// We use plain blocking flock (LOCK_EX) rather than a LOCK_NB + sleep
// poll loop. On macOS the kernel can take tens of ms to release a
// dropped flock after the holding process exits; polling with LOCK_NB
// pays back-to-back scheduler pauses that show up as ~200ms p99 tail
// outliers. Blocking LOCK_EX is kernel-driven and adds <1ms in the
// uncontended case.
//
// There is no userspace timeout: deadlock is impossible (no recursive
// locking; defer-unlock on every path). If the kernel were to hang the
// lock, the agent's own hook timeout (Claude: 5s by default) is the
// outer cap.
func withStateLock(root, id string, fn func() error) error {
	if err := ensureSessionStateDir(root, id); err != nil {
		return err
	}
	lockPath := SessionStateLockPath(root, id)
	f, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return fmt.Errorf("open state lock: %w", err)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX); err != nil {
		return fmt.Errorf("acquire state lock for %s: %w", id, err)
	}
	defer syscall.Flock(int(f.Fd()), syscall.LOCK_UN) //nolint:errcheck
	return fn()
}

func ensureSessionStateDir(root, id string) error {
	dir := SessionStateDir(root, id)
	if _, ok := ensuredSessionStateDirs.Load(dir); ok {
		if info, err := os.Stat(dir); err == nil && info.IsDir() {
			return nil
		}
	}
	if err := EnsurePrivateStateRoot(root); err != nil {
		return fmt.Errorf("create state root: %w", err)
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create session state dir: %w", err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return fmt.Errorf("restrict session state dir: %w", err)
	}
	ensuredSessionStateDirs.Store(dir, struct{}{})
	return nil
}
